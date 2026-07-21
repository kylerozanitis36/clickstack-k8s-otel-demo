# Design: configurable, always-on OTel Demo failure scenarios

**Date:** 2026-07-15
**Status:** approved (design)

## Problem

The goal is an always-fresh, reproducible demo environment that continuously
exhibits real error patterns — feeding live telemetry (traces, metrics, logs) into
a self-hosted Managed ClickStack — so customers can be walked through failing
distributed traces and correlated infrastructure metrics without relying on the
shared `play-clickstack.clickhouse.com` playground.

Investigation of the running cluster found the infrastructure is **already fully
deployed**:

- `load-generator` (Locust, `LOCUST_HEADLESS`/`LOCUST_AUTOSTART`, browser traffic
  enabled) is running and has been driving traffic for ~20h. Telemetry already flows
  through the gateway to ClickHouse Cloud.
- The full ~20-service mesh (`payment`, `checkout`, `cart`, `fraud-detection`,
  `kafka`, etc.) is up.
- `flagd` runs with all failure-scenario feature flags **defined but every one
  defaulted to `off`**.

So the only gap is that **no failure scenario is ever enabled**, and there is no
declarative, checked-in, reproducible way to keep scenarios continuously active —
today it would require hand-editing flagd on every deploy.

The classic "Visa cache fills up → `Failed to place order`" narrative maps, in this
demo version (chart `opentelemetry-demo-0.40.9`, appVersion `2.2.0`), to the
`paymentFailure` flag family — the flag names changed across versions but the
charge-failure symptom is identical. There is no longer a literally-named "Visa
cache" flag.

## Goal

Make selected failure scenarios **continuously active by default** and
**configurable at deploy time**, in a way that is declarative, idempotent, and
reproducible — matching the existing `make otel-up` workflow.

Default (a bare `make otel-up`) enables three complementary scenarios:

| Flag | Variant | Story |
|------|---------|-------|
| `paymentFailure` | `25%` | ~1 in 4 checkouts fails at the charge step -> `Failed to place order`. Headline trace: frontend -> checkout -> payment with a clean success/failure split. |
| `recommendationCacheFailure` | `on` | recommendation-service cache errors + memory growth (correlated infra metrics). |
| `productCatalogFailure` | `on` | errors on one specific product (a localized error-rate spike). |

"Steady partial failures" model: healthy baseline traffic plus a constant,
contrasting stream of errors — the same story every time.

## Approach

### Why a deploy-time delta-patch (approach A)

The demo chart generates the `flagd-config` ConfigMap from a **static file baked
into the chart** (`templates/flagd-config.yaml` renders
`(.Files.Glob "flagd/*.json").AsConfig`). There is **no Helm value** to override the
flag JSON. Two rejected alternatives:

- **Full static copy** of `demo.flagd.json` checked into the repo + a
  `components.flagd.additionalVolumes` values override. Simplest logic, but the
  ~15-flag file drifts from the chart on every version bump and buries the small
  intent (3 flags) inside a large blob, and couples us to the chart's volume layout.
- **Runtime toggle only** (a `make` target that flips flags on demand). Not
  declarative, not continuous — contradicts the always-on goal.

Chosen: **delta-patch at deploy time.** We encode only the intent (which flags ->
which variants), render the chart's canonical flag JSON for the pinned version,
apply the delta, and deliver it to flagd — self-healing on chart upgrades (we never
copy the full catalog) and keeping intent obvious.

**Delivery: our own ConfigMap, not the chart's.** The obvious delivery — overwrite
the chart-managed `flagd-config` ConfigMap in place — does **not** work: this Helm
version uses server-side apply and re-applies `flagd-config` on every
`helm upgrade`, so a `kubectl apply` of our patched content takes field ownership of
`.data."demo.flagd.json"` and the next `helm upgrade` then **fails** with a
field-manager conflict. So instead we write the patched JSON into our **own**
ConfigMap `flagd-config-scenarios` and point flagd at it via a
`components.flagd.additionalVolumes` override in `otel-demo-values.yaml` (the init
container still copies `/config-ro/demo.flagd.json`, so the key name is unchanged).
The chart's `flagd-config` is left untouched (created but unused), so there is no
ownership fight. This does couple us to the chart's flagd volume names
(`config-ro` / filename `demo.flagd.json`), which are stable; the fail-fast
validation and a flagd rollout catch any future drift.

### flagd reads the file once at startup

flagd's pod uses an init-container to copy the ConfigMap file into an emptyDir that
flagd then reads; it does **not** re-read on ConfigMap change. Therefore any flag
change requires a **flagd pod restart** (`kubectl rollout restart deploy/flagd`).
This is why the mechanism restarts flagd as its last step.

### Delta-patch flow (in `scripts/deploy-otel.sh`)

All resolution + validation happens **before any deploy**, so a bad `SCENARIOS`
fails fast without touching the cluster:

1. **Render the canonical flag JSON + validation catalog** for the pinned chart:
   `helm pull open-telemetry/opentelemetry-demo --untar` and read
   `flagd/demo.flagd.json` (pure JSON, directly `jq`-readable — no YAML parsing).
   This is the single source of truth for both valid flag names and each flag's valid
   variants, so validation never drifts from the chart. The demo is then installed
   from this same pulled chart, so the catalog always matches what is deployed.
2. **Resolve the selection** from `SCENARIOS` (or the default set), **validate**
   each entry against the catalog, and build a `jq` filter that sets
   `.flags[<name>].defaultVariant = <variant>` for each selected flag. All other
   flags remain `off`. Unknown flag/variant or a variant-less flag with no `on`
   variant exits non-zero here.
3. Apply the patched JSON into our **own** ConfigMap
   `flagd-config-scenarios` (`kubectl create configmap flagd-config-scenarios
   -n otel-demo --from-file=demo.flagd.json=<patched> --dry-run=client -o yaml |
   kubectl apply -f -`) — before the demo install, so flagd can mount it on first
   start. We own this ConfigMap outright, so the apply is clean and idempotent.
4. `helm upgrade --install otel-demo <pulled-chart> …` with
   `otel-demo-values.yaml` pointing flagd's `config-ro` volume at
   `flagd-config-scenarios`.
5. `kubectl -n otel-demo rollout restart deploy/flagd` (flagd reads the flag file
   only at startup, so a content change on a re-run needs a rollout).

The flow is idempotent: our ConfigMap is re-applied and flagd re-rolled every run,
and Helm never contends for it. `otel-demo-values.yaml` gains a small
`components.flagd.additionalVolumes` override (the config-ro mount) so flagd loads
our ConfigMap instead of the chart's static `flagd-config`.

## Interface: the `SCENARIOS` variable

`make otel-up SCENARIOS="…"` -> Make passes `SCENARIOS` to `deploy-otel.sh`.

| Input | Behavior |
|-------|----------|
| unset (bare `make otel-up`) | the 3 defaults (`paymentFailure=25%`, `recommendationCacheFailure=on`, `productCatalogFailure=on`) |
| `SCENARIOS=none` | zero scenarios — all failure flags stay `off` (clean/healthy demo) |
| `SCENARIOS="flag[=variant] …"` | exactly the listed flags, everything else `off` |

**Syntax:** space-separated `flag[=variant]` entries.

- **Bare flag shorthand:** resolves to `on` if the flag has an `on` variant;
  `paymentFailure` bare resolves to `25%` (it has no `on` variant); any other flag
  with no `on` variant and no explicit variant given is a **hard error** listing its
  valid variants.
- **Validation:** every flag name and variant is checked against the rendered
  catalog. Unknown flag or unknown variant -> exit non-zero with the valid list. No
  silent no-ops.
- `none` is a reserved keyword and cannot be combined with flags.

## Components

| File | Change |
|------|--------|
| `scripts/deploy-otel.sh` | Add (early, fail-fast) SCENARIOS parse/validate + pull chart + `jq` delta-patch; apply `flagd-config-scenarios` ConfigMap; install demo from the pulled chart; `rollout restart deploy/flagd`. |
| `otel/otel-demo-values.yaml` | Add `components.flagd.additionalVolumes` (config-ro) pointing flagd at `flagd-config-scenarios` instead of the chart's `flagd-config`. |
| `scripts/preflight.sh` | Ensure `jq` is installed. |
| `scripts/list-scenarios.sh` | New: pull the chart and print every flag + its variants + description (backs `make otel-scenarios`). |
| `Makefile` | `otel-up` passes `SCENARIOS` through (`@SCENARIOS="$(SCENARIOS)" scripts/deploy-otel.sh`); new `otel-scenarios` target prints the available flags + variants (discoverability for the `flag=variant` syntax). |
| `CLAUDE.md` | Document `SCENARIOS`, the three modes, and the "flag JSON baked into chart -> mount a delta-patched ConfigMap + restart flagd" gotcha. |
| `README.md` | Document `make otel-up SCENARIOS=…`. |

Dependencies: `jq` (added to `scripts/preflight.sh`).

## Error handling

- `deploy-otel.sh` keeps `set -euo pipefail`.
- Unknown flag name, unknown variant, or a variant-less flag with no `on` variant
  each exit non-zero with an actionable message and the valid options.
- `SCENARIOS=none` combined with other tokens is rejected.
- Rendering the catalog failing (e.g. chart/network issue) surfaces the helm error.

## Verification

1. **Default run** (`make otel-up`): `flagd-config` shows `paymentFailure`
   `defaultVariant=25%`, `recommendationCacheFailure=on`, `productCatalogFailure=on`;
   flagd pod healthy after restart.
2. **Live telemetry:** query ClickHouse Cloud (via the gateway) for payment/checkout
   error spans + `Failed to place order` over the last few minutes; confirm roughly a
   25% checkout failure rate.
3. **`SCENARIOS=none`:** all flags `off`; error spans drain away.
4. **`SCENARIOS="cartFailure=on"`:** only cart fails.
5. **Error cases:** a bad flag name and a bad variant each exit non-zero with a
   helpful message.
6. **Idempotency:** re-running `make otel-up` yields stable state.

## Out of scope

- **Session replay** (adding the HyperDX browser SDK / rrweb to the frontend) — a
  separate spec.
- Rotating / scheduled scenarios (a controller that cycles flags over time).
- Re-enabling the flagd-ui sidecar (stays disabled; it OOMs at 250Mi and the patch
  step replaces its purpose for this workflow).
