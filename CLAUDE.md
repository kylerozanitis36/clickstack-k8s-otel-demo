## Project Overview
This purpose of this project is to understand and demonstrate how to run a Kubernetes cluster locally on a MacBook Pro, and collect the logs, metrics, and traces using an OpenTelemetry collector.

## Tech Stack
Local: Kubernetes cluster, OpenTelemetry collector
Cloud Hosted: ClickHouse Cloud Service, ClickStack/HyperDX UI

## Local Cluster
The local cluster runs on [kind](https://kind.sigs.k8s.io/) (Kubernetes-in-Docker) backed
by Docker Desktop. Topology: 1 control-plane + 2 workers, so node-level telemetry is meaningful.

- Tool: kind v0.32.0 / Kubernetes v1.36.1 (node image digest pinned in `.env` for reproducibility).
- Config is fully declarative: [kind/cluster-config.yaml](kind/cluster-config.yaml) is a template
  rendered with `envsubst` (from `.env`) by `scripts/create-cluster.sh`.
- kubeconfig is project-local at `./.kube/config` (isolated from `~/.kube/config`), context `kind-clickstack-local`.
- Control-plane reserves host ports `8080->:80` and `8443->:443`; `8080->:80` is now
  used by the ingress controller (see "Demo UI ingress" below). `8443->:443` still free.
- kind nodes already expose `/var/log/pods` + `/var/log/containers`, so a future OTel DaemonSet can
  hostPath-mount them with no extra cluster config.

### Common commands
- `cp .env.example .env` — one-time setup (`.env` is gitignored).
- `make up` / `make down` / `make recreate` — create / delete / rebuild the cluster (idempotent).
- `make pause` / `make resume` — stop / start the kind node containers to suspend the
  cluster without deleting it (state preserved; workloads self-heal on resume). Scripts:
  `scripts/pause-cluster.sh` / `scripts/resume-cluster.sh` (identify nodes via the
  `io.x-k8s.kind.cluster=$CLUSTER_NAME` Docker label).
- `make status` — show nodes and all pods.
- `eval "$(make -s kubeconfig)"` — point kubectl at this cluster.
- Prerequisites: Docker Desktop running, Homebrew. `make up` installs `kind`/`helm`/`gettext` if missing.

## OpenTelemetry Collection (phase 2 — done)
Pipeline shipping logs/metrics/traces to ClickHouse Cloud, viewed in Cloud's HyperDX UI.
Design + plan: [docs/superpowers/specs/](docs/superpowers/specs/) and [docs/superpowers/plans/](docs/superpowers/plans/).

- **Gateway** (`clickstack-gateway`, ClickStack collector image) in `observability` — the only
  component that exports to ClickHouse Cloud; credentials come from the `clickhouse-credentials`
  Secret (built from `.env`). It auto-seeds the ClickHouse schema on startup.
- **Agents** in `observability`: `otel-agent` (DaemonSet — container logs + host/kubelet metrics,
  runs on all 3 nodes via a control-plane toleration) and `otel-cluster` (Deployment — k8s events
  + cluster metrics). Both send OTLP to the gateway Service.
- **OTel Demo** (`otel-demo` ns) generates app telemetry. It has **no bundled collector**:
  the fork's design has apps export straight to the ClickStack collector, so an
  `ExternalName` Service aliases `my-clickstack-otel-collector` to our gateway. A
  consequence is no spanmetrics — HyperDX derives service health from traces. If we ever
  want spanmetrics it belongs in the gateway, not the demo.
- Values files live in `otel/` (gateway + agents only): `gateway-values.yaml`,
  `k8s-daemonset-values.yaml`, `k8s-deployment-values.yaml`. The demo lives in
  `otel-demo/` and is applied with kustomize, not Helm.
  Commands: `make demo-images`/`otel-up`/`otel-down`/`otel-status`.

### OTel Demo (fork manifest)
The demo is deployed from **ClickHouse's fork manifest**, not the upstream Helm chart:
`otel-demo/upstream/opentelemetry-demo.yaml` is a verbatim copy pinned to
`CLICKHOUSE_DEMO_FORK_REF`, customised by `otel-demo/kustomization.yaml` and applied with
`kubectl apply -k otel-demo/`. `scripts/check-overlay.sh` asserts the overlay's invariants
and runs on every deploy.

- **Images are built locally.** The fork publishes **amd64-only** images, so
  `make demo-images` builds all 19 services from source for this host
  (`clickstack-local/ch-otel-demo:latest-*`) and `kind load`s them. ~12 min first run,
  cached after. The overlay retargets the image *name*, which exists on no registry, so
  nothing can pull the amd64 originals back over them. `make otel-up` refuses to deploy if
  the images, the vendored manifest and `.env` disagree on the fork SHA.
- **Two source patches** are applied to the clone at build time, never to vendored files,
  and both fail loudly if they stop applying: `accounting`'s `TreatWarningsAsErrors`
  (its `NuGetAudit` runs at level `low`, so OpenTelemetry advisories published after the
  pinned commit become build errors — this breaks on amd64 too), and the artillery
  Dockerfile (its `artilleryio/artillery` base is amd64-only on **every** published tag;
  we build on `mcr.microsoft.com/playwright` instead). Build success is not enough — the
  script asserts each image's architecture, because a single-arch base yields a wrong-arch
  image from a perfectly successful build.
- **Failure scenarios** are the fork's flagd defaults (`paymentCacheLeak` on). There is no
  `SCENARIOS` variable any more — toggle flags interactively in the flagd-ui
  (`kubectl -n otel-demo port-forward deploy/flagd 4000:4000`). The overlay sets the payment
  cache to 10 (the manifest ships 100000, at which the incident never fires).
- **Two load generators** run: the Locust API user, and `artillery-loadgen`, which drives a
  real Chromium browser through the storefront.
- **Never `kubectl apply` over a legacy Helm release** — `spec.selector` is immutable, so the
  conversion fails per Deployment. `deploy-otel.sh` checks for the release and tells you to
  run `make otel-down` first.
- **Upgrading the fork:** bump `CLICKHOUSE_DEMO_FORK_REF`, run
  `scripts/refresh-demo-manifest.sh`, review the `git diff` of `otel-demo/upstream/`, then
  `make demo-images`.

### Replicating the ClickStack remote-demo walkthrough (HyperDX sources)
The `remote-demo-data` walkthrough reads **four HyperDX data sources** — Logs, Traces,
Metrics, Sessions. The ClickStack collector auto-creates the ClickHouse **tables**, but a
HyperDX **source** (app-level config pointing HyperDX at a table + column/correlation
mappings) is a **separate** thing that is **not** auto-created for a user's own ClickHouse.
That's why traces (no `Trace` button) and metrics (no metrics view) don't appear until the
sources are configured. Steps 1–13 are covered by:
1. `make demo-images && make otel-up` — the fork images make the incident, the
   `visa_validation_cache.size` gauge and the `Failed to place order` log the default
   behaviour; `paymentCacheLeak` is on in the fork's flagd config.
2. `make hyperdx-sources` — configures/prints the Logs/Traces/Metrics/Sessions sources
   (`scripts/configure-hyperdx-sources.sh`). For **Managed ClickStack** it uses the
   **ClickHouse Cloud API** (`api.clickhouse.cloud/v1/.../clickstack/sources`, Basic auth
   with a Cloud API key; `.env`: `CLICKHOUSE_CLOUD_ORG_ID`/`_SERVICE_ID`/`_API_KEY_ID`/
   `_API_KEY_SECRET`) with `APPLY=1`; else it prints exact values for Team Settings →
   Sources. The Cloud source-**create** endpoints are **Beta**, so the UI steps (README)
   are the verified path. (Self-hosted HyperDX uses a different API — Bearer + `:8000/api/v2`
   — not what this script targets.)
Session replay (steps 14–15) needs browser RUM and is tracked as a GitHub issue.
Design: [docs/superpowers/specs/2026-07-22-walkthrough-replication-design.md](docs/superpowers/specs/2026-07-22-walkthrough-replication-design.md).

### Gotchas (learned during setup)
- Agent collector image tag **must match the helm chart's appVersion** (`0.154.0`); the
  `kubernetesAttributes` preset emits config keys older images reject (crash loop).
- The demo's bundled collector, the hostPort clashes, the double-counted infra metrics and
  the kubelet-cert log flood are all gone with the chart — the fork manifest ships no
  collector at all.

## Demo UI ingress (phase 3 — done)
`make ingress-up` (run after `make otel-up`) exposes the OTel Demo storefront on
`http://localhost:8080`. It deploys ingress-nginx via kind's static manifest (pinned in
`scripts/deploy-ingress.sh`) and applies `ingress/frontend-ingress.yaml` (routes `/` to
`otel-demo/frontend-proxy:8080`). `make ingress-down` removes it; `make ingress-status` shows it.

### Gotchas (learned during setup)
- kind maps host `8080 -> control-plane node :80`, and ingress-nginx binds `hostPort` 80.
  Newer ingress-nginx kind manifests (v1.15.x) dropped the `ingress-ready` nodeSelector, so
  on a **multi-node** cluster the controller could land on a worker (no host mapping). The
  deploy script therefore **patches the controller's nodeSelector to
  `node-role.kubernetes.io/control-plane`** so it lands on the node with the port mapping;
  the manifest already tolerates the control-plane taint.
- The script waits for the controller `Ready` (admission webhook serving) before applying the
  Ingress, then verifies `localhost:8080` returns 200.

## Status / Next Steps
Done: local cluster hosting (phase 1) + OTel collection into ClickHouse Cloud (phase 2)
+ demo UI ingress on localhost:8080 (phase 3).
Possible next: dashboards/alerts in HyperDX, sampling/retention tuning, or app-level
instrumentation beyond the demo.
