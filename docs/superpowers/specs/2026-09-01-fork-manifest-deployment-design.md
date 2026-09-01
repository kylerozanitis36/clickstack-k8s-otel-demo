# Design: deploy the OTel Demo from ClickHouse's fork manifest (locally built arm64 images)

**Date:** 2026-09-01
**Status:** approved (design)

## Problem

[ClickHouse/opentelemetry-demo#30](https://github.com/ClickHouse/opentelemetry-demo/pull/30)
("Update demo data and instrumentation", merged 2026-08-31) refreshed the fork's mock data and
instrumentation. Our pinned `CLICKHOUSE_DEMO_FORK_REF=15969bb3` → fork `main` (`d658416`) is
**exactly** that PR and nothing else, so the PR diff is our whole upgrade delta.

Reviewing it established that it does **not** obsolete our workarounds *while we keep the
upstream Helm chart*:

- `@hyperdx/node-opentelemetry` was bumped `^0.8.1` → `^0.10.3`, but the api-key gate is
  unchanged — `build/src/otel.js:111` still hard-returns ("OpenTelemetry SDK initialization
  skipped") unless `HYPERDX_API_KEY` or `OTEL_EXPORTER_OTLP_HEADERS` is set — and it still
  derives OTLP/HTTP URLs as `OTEL_EXPORTER_OTLP_ENDPOINT` + `/v1/<signal>`
  (`build/src/constants.js:15,25,31`), while the chart's base stays gRPC `:4317`.
- Our architecture borrows only **3 of the fork's 19** images, so PR #30's new instrumentation
  in `checkout`, `ad`, `product-catalog`, `recommendation` and `shipping` never reaches us.

Meanwhile the fork now maintains a complete Kubernetes path — `kubernetes/opentelemetry-demo.yaml`,
53 resources — in which every one of those problems is already solved: OTLP endpoints on `:4318`,
`HYPERDX_API_KEY` wired from an optional Secret, `paymentCacheLeak` on by default, `CACHE_SIZE`
present, and both load generators. Its only blocker is that the fork's published images are
**amd64-only** while our host is arm64.

The reason none of this bites in `docker compose` is instructive: compose **builds all 19 services
from source for the host arch**, and the fork ships our "workarounds" as defaults — a placeholder
`HYPERDX_API_KEY` in `.env`, an HTTP `:4318` endpoint base, `LOCUST_BROWSER_TRAFFIC_ENABLED=false`,
`CACHE_SIZE=1`. Our diff is not a fork-quality problem; it is the cost of three choices: K8s
instead of compose, the upstream chart instead of the fork's own deployment, and ClickHouse Cloud
instead of the bundled backend.

So: build the fork's images locally for arm64 and adopt its manifest. That removes the reason our
overlays exist, and it is the only way we actually receive PR #30's instrumentation everywhere.

## Approach

Replace the upstream Helm chart with the fork's manifest, vendored pristine at a pinned SHA and
customised through a kustomize overlay. Images are built locally from the same pinned SHA via
`docker compose build` and loaded into kind. The `observability` namespace (gateway + agents),
the ingress, and `make hyperdx-sources` are unchanged.

Telemetry path becomes: demo apps → OTLP → Service `my-clickstack-otel-collector` (an
`ExternalName` alias we add) → `clickstack-gateway` → ClickHouse Cloud.

Consequence worth stating plainly: **the demo's bundled collector disappears.** The fork's K8s
design has apps export straight to the ClickStack collector. We lose spanmetrics-derived RED
metrics (ClickHouse's intended design — HyperDX derives service health from traces), and in
exchange the hostPort collisions, double-counted infra metrics, kubelet-cert log flood and
spanmetrics re-listing hacks all cease to exist. If spanmetrics is ever wanted it belongs in our
gateway config, not the demo.

## Verified during the build spike (2026-09-01)

Findings that this design depends on, all measured rather than assumed:

- **17 of 19 services are usable as shipped**, built in 11.5 min sequential on a 14-core / 48 GB
  host (`ad`, `cart`, `checkout`, `currency`, `email`, `flagd-ui`, `fraud-detection`, `frontend`,
  `frontend-proxy`, `image-provider`, `kafka`, `load-generator`, `payment`, `product-catalog`,
  `quote`, `recommendation`, `shipping`). The spike reported 18 PASS / 1 FAIL, but one of those
  passes — `artillery` — is false (see below), so the two exceptions are `accounting` and
  `artillery`, both with verified fixes.
- **`accounting` fails for a non-arch reason.** `src/accounting/Directory.Build.props` sets
  `NuGetAudit=true` + `NuGetAuditLevel=low` + `TreatWarningsAsErrors=true` (Release), so five
  OpenTelemetry 1.11.x advisories published *after* the pinned commit become `NU1902` build
  errors. This breaks on amd64 too — `docker compose build` is currently broken for everyone.
  Verified fix: remove the single `<TreatWarningsAsErrors>` line → builds, `linux/arm64`.
- **`artillery` is a false pass.** It builds successfully but yields a **`linux/amd64`** image,
  because its base `artilleryio/artillery` is single-arch on all 77 Docker Hub tags. It would
  have deployed and then crash-looped with `exec format error`. Verified replacement: our own
  ~10-line Dockerfile on `mcr.microsoft.com/playwright:v1.50.0-jammy` (amd64+arm64) reusing the
  fork's `flows.js` / `load-test.template.yaml` / faker `package.json` — builds arm64 in 39 s,
  the Playwright engine launches, and it drove 35 browser HTTP requests (21 × 200) against the
  live demo.
- **The kustomize overlay renders correctly** with kustomize v5.8.1 (built into kubectl v1.36.1):
  a single `images:` entry retargets all 19 fork images (they share one image *name*, differing
  only by tag); two JSON6902 stanzas cover every `imagePullPolicy` (all Deployments have
  `containers[0]`, only `flagd` has `containers[1]`); a strategic-merge patch sets payment's
  `CACHE_SIZE` (env merges by name); and `$patch: delete` against regex name targets strips
  Jaeger and the orphaned prometheus RBAC (54 → 46 resources).
- **The cross-namespace `ExternalName` alias works** — created against the live cluster, a pod in
  `otel-demo` reached both TCP 4317 and 4318 through it.
- **All third-party images in the manifest are multi-arch**: flagd v0.11.1, valkey 7.2-alpine,
  busybox (and Jaeger, which we delete anyway).

## Changes

### New: `otel-demo/`

```
otel-demo/
  upstream/opentelemetry-demo.yaml   # verbatim fork manifest @ pinned SHA; never hand-edited
  upstream/SOURCE                    # repo, SHA, date vendored
  kustomization.yaml                 # our deltas — the only file a reader needs
  gateway-alias-service.yaml         # ExternalName my-clickstack-otel-collector -> gateway
  artillery/Dockerfile               # ours: multi-arch replacement for the amd64-only base
  artillery/run.sh                   # ours: `artillery run` instead of the base image's wrapper
```

The overlay carries exactly six things:

1. `namespace: otel-demo`.
2. `images:` — one entry retargeting `clickhouse/ch-otel-demo` → `clickstack-local/ch-otel-demo`.
   Renaming is deliberate belt-and-braces: with a name that does not exist on Docker Hub, a stray
   `Always` cannot silently pull amd64 over our arm64 build.
3. `imagePullPolicy: IfNotPresent` on all Deployment containers (two JSON6902 stanzas).
4. `CACHE_SIZE: "10"` on payment, replacing the manifest's `100000` — at 100000 the Visa incident
   effectively never fires.
5. Deletion of Jaeger (Deployment + 3 Services + SA) and the orphaned prometheus /
   otel-collector RBAC.
6. Our two extra resources: the gateway alias Service, and a `hyperdx-secret` holding a dummy
   key (the manifest reads it as an *optional* Secret; supplying it makes the SDK's init path
   deliberate rather than relying on Kubernetes leaving a literal `$(HYPERDX_API_KEY)` behind).

Local image tags stay fixed (`:latest-<svc>`) so the overlay is static. `build-demo-images.sh`
records the fork SHA it built into `.cache/demo-images.sha`; `deploy-otel.sh` compares that against
`CLICKHOUSE_DEMO_FORK_REF` and fails fast with "run `make demo-images`" when it is missing or stale.

`CLICKHOUSE_DEMO_FORK_REF` is the **single** source of truth for the fork version: the images and
the vendored manifest must come from the same commit. `refresh-demo-manifest.sh` writes that SHA
into `otel-demo/upstream/SOURCE`, and `deploy-otel.sh` verifies `SOURCE`, `.env` and
`.cache/demo-images.sha` all agree before applying — a manifest from one commit with images from
another is the most likely way this setup could break subtly, so it is checked rather than trusted.

### New scripts

- `scripts/build-demo-images.sh` — clone the fork at `CLICKHOUSE_DEMO_FORK_REF` into `.cache/`,
  apply the two documented source patches (accounting `TreatWarningsAsErrors`; swap the artillery
  Dockerfile for ours), `IMAGE_NAME=clickstack-local/ch-otel-demo docker compose build`,
  `kind load` all 19, write `.cache/demo-images.sha`. Per-service pass/fail so one failure does
  not mask the rest, and a post-build `docker image inspect` arch assertion so an amd64 image can
  never pass silently again.
- `scripts/refresh-demo-manifest.sh` — re-vendor `otel-demo/upstream/` at a given SHA and update
  `SOURCE`, so upgrades are a reviewable `git diff` of the fork's own file.

### Rewritten

- `scripts/deploy-otel.sh` — keeps namespaces, the credentials Secret, the `otel-config-vars`
  ConfigMap, the gateway and the two agents. The demo section collapses to a staleness check plus
  `kubectl apply -k otel-demo/`. Loses ~120 lines of scenario resolution/validation, the
  `helm pull`, the chart pin and the envsubst rendering.
- `Makefile` — add `demo-images`; drop `otel-scenarios`.

### Deleted

`otel/otel-demo-values.yaml`, `otel/otel-demo-visa-cache-values.yaml`,
`otel/flagd-extra-flags.json`, `scripts/list-scenarios.sh`, and from `.env`/`.env.example` the
`DEMO_CHART_VERSION` and `VISA_CACHE_SIZE` knobs.

### Docs

`CLAUDE.md` and `README.md` lose the gotchas about chart hostPorts, demo-collector infra presets,
flagd field-ownership, the SDK gRPC/HTTP endpoint override, the `HYPERDX_API_KEY` hard-return and
the Playwright browser-traffic bug — none are ours to explain any more. They gain the fork-manifest
model, `make demo-images`, and the two source patches with their reasons. The configurable-scenarios
and visa-cache design docs are marked **superseded** rather than deleted.

## Non-goals

- **The `SCENARIOS` interface.** Dropped by decision. The fork's flagd defaults (`paymentCacheLeak`
  on) ship as-is, and the flagd-ui sidecar — which the manifest gives a 400Mi limit, unlike the
  250Mi that OOMed under the chart — becomes the interactive way to toggle failure scenarios.
- **spanmetrics.** See Approach; revisit in the gateway if wanted.
- **Publishing images to a registry.** Colleagues build locally.
- **Session replay end to end.** Artillery unlocks real browser traffic, which is the prerequisite;
  confirming a working Sessions source remains a follow-up.

## Risks

- **Fork drift.** We now carry two source patches and an owned Dockerfile. Both are narrow and
  live in one script; `refresh-demo-manifest.sh` plus a pinned SHA keeps upgrades deliberate. The
  build script must fail loudly if a patch no longer applies rather than building unpatched.
- **The accounting patch relaxes a deliberate security gate** for a local demo build. Documented
  in place, and reported upstream so the real fix (package bumps) lands with the fork.
- **Resource footprint.** 21 Deployments with the manifest's own limits, versus the chart's. The
  currently running chart-based demo already has `checkout` in `OOMKilled`, so limits need a look
  under the new manifest on a 3-node kind cluster.
- **First-run cost** is ~12 min of building, opt-in via `make demo-images`.

## Verification

1. `make demo-images` — all 19 report PASS and every image asserts `linux/arm64`.
2. `make otel-up` — all pods Ready; no `ImagePullBackOff`, no `exec format error`, no `OOMKilled`.
3. Spans, logs and metrics from demo services arrive in ClickHouse Cloud through the alias.
4. `make ingress-up` — storefront answers 200 on `http://localhost:8080`.
5. The Visa incident fires: `Visa cache full: cannot add new item.` → `Failed to place order`
   with a populated `TraceId` (working Trace button) and the `visa_validation_cache.size` gauge.
6. Walkthrough steps 1–13 re-verified end to end.
7. Artillery produces browser traffic; note whether Sessions data appears.

## Findings to report upstream

Discovered while reviewing PR #30; worth sending to the PR author:

1. `src/otel-collector/otelcol-config.yml:101-103` is **invalid YAML** —
   `send_batch_max_size`/`timeout` are indented as children of the scalar `send_batch_size`.
   Confirmed: `mapping values are not allowed in this context at line 103 column 26`. The compose
   collector cannot load this config.
2. The .NET runtime-metrics fix is a **no-op in Kubernetes**: compose sets
   `OTEL_DOTNET_AUTO_METRICS_NETRUNTIME_INSTRUMENTATION_ENABLED=true` (the per-instrumentation
   toggle) but `kubernetes/opentelemetry-demo.yaml:1143` sets
   `OTEL_DOTNET_AUTO_METRICS_INSTRUMENTATION_ENABLED=true`, the global toggle that already
   defaults to true.
3. `OTEL_EXPORTER_OTLP_HEADERS: "authorization=$(HYPERDX_API_KEY)"` with an `optional: true`
   Secret: when the Secret is absent, Kubernetes leaves the literal `$(HYPERDX_API_KEY)` and every
   service sends a garbage auth header. It accidentally satisfies the SDK's api-key gate, which is
   probably why it appears to work.
4. `docker compose build` is **broken today** on `accounting` (finding above) — a pinned commit
   plus `NuGetAuditLevel=low` and `TreatWarningsAsErrors` cannot both hold as advisories accrue.
5. `artillery-loadgen`'s base image is **amd64-only**, so the K8s manifest cannot run on ARM
   nodes (Apple Silicon laptops, Graviton).
6. `CACHE_SIZE` is `1` in compose but `100000` in the K8s manifest, so the Visa incident fires
   instantly in one and effectively never in the other.
7. The manifest pins nothing (`:latest-*` with `imagePullPolicy: Always`) and ships Jaeger plus
   orphaned prometheus/otel-collector RBAC with no corresponding workloads.
