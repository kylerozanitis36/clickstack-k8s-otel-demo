# clickstack-k8s-otel-demo

Run a lightweight, multi-node Kubernetes cluster locally on macOS, as the foundation
for collecting logs, metrics, and traces with an OpenTelemetry collector and shipping
them to ClickHouse Cloud / ClickStack (HyperDX) via a standalone OpenTelemetry collector
acting as a gateway.

The cluster uses [kind](https://kind.sigs.k8s.io/) (Kubernetes-in-Docker) and is fully
declarative so others can recreate the exact same cluster from checked-in config.

## Prerequisites

- macOS with [Homebrew](https://brew.sh)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed **and running**
- `kubectl` (the scripts install `kind`, `helm`, and `gettext`/`envsubst` for you if missing)

## Quick start

```bash
cp .env.example .env     # adjust CLUSTER_NAME / node image if desired
make up                  # create the 3-node cluster (1 control-plane + 2 workers)

# Point kubectl at the project-local kubeconfig:
eval "$(make -s kubeconfig)"
make status              # nodes + pods
```

## Cluster layout

| Setting     | Value                                              |
|-------------|----------------------------------------------------|
| Tool        | kind v0.32.0                                       |
| Kubernetes  | v1.36.1 (pinned node image digest in `.env`)       |
| Topology    | 1 control-plane + 2 workers                        |
| Host ports  | `8080 -> :80`, `8443 -> :443` (reserved for ingress) |
| kubeconfig  | `./.kube/config` (isolated from `~/.kube/config`)  |

## Make targets

| Target            | Description                                  |
|-------------------|----------------------------------------------|
| `make up`         | Create the cluster (idempotent)              |
| `make down`       | Delete the cluster                           |
| `make recreate`   | Tear down and rebuild from scratch           |
| `make pause`      | Pause the cluster (stop nodes; state kept)   |
| `make resume`     | Resume a paused cluster                      |
| `make status`     | Show nodes and all pods                      |
| `make kubeconfig` | Print the `export KUBECONFIG=...` line       |
| `make demo-images`| Build the demo-fork images for this arch     |

### Pause / resume

To stop the cluster without tearing it down (e.g. to free CPU/RAM or step away),
`make pause` stops the kind node containers; all cluster and workload state is preserved
on disk. `make resume` starts them again and waits for the nodes to come back `Ready` —
your OTel pipeline and demo self-heal (pods restart) and telemetry resumes on its own, no
`make otel-up` needed. This is far faster than `make recreate`, which rebuilds from scratch.

```bash
make pause     # stop node containers (kubectl / localhost:8080 go offline)
make resume    # start them, wait for Ready; workloads come back automatically
```

## How it works

- [`.env`](.env.example) holds the cluster name, pinned node image, kubeconfig path, and
  the ClickHouse Cloud endpoint/credentials + gateway endpoint.
- [`kind/cluster-config.yaml`](kind/cluster-config.yaml) is a template; `scripts/create-cluster.sh`
  renders it with `envsubst` and feeds it to `kind`.
- [`scripts/preflight.sh`](scripts/preflight.sh) checks Docker is running and installs missing tools.
- [`otel/`](otel/) holds the Helm values for the OpenTelemetry pipeline (see below).

### Repository layout
```
.env(.example)            cluster + ClickHouse Cloud config (.env is gitignored)
Makefile                  make up/down/recreate/pause/resume/status/kubeconfig + demo-images/otel-up/otel-down/otel-status
kind/cluster-config.yaml  kind cluster manifest (template)
otel/                     OpenTelemetry Helm values (gateway + agents only):
  gateway-values.yaml       gateway → ClickHouse Cloud (the only egress)
  k8s-daemonset-values.yaml per-node agent: logs + host/kubelet metrics
  k8s-deployment-values.yaml single agent: k8s events + cluster metrics
otel-demo/                the demo, deployed with kubectl apply -k:
  upstream/                 verbatim copy of the fork's manifest @ a pinned SHA
  kustomization.yaml        our delta (images, pull policy, cache size, deletions)
  gateway-alias-service.yaml  points the demo's collector name at our gateway
  artillery/                multi-arch replacement for the amd64-only artillery image
ingress/frontend-ingress.yaml  Ingress exposing the demo UI on localhost:8080
scripts/                  create/delete/pause/resume cluster + deploy/teardown OTel + ingress
                          + configure-hyperdx-sources.sh (HyperDX Logs/Traces/Metrics/Sessions)
docs/superpowers/         design spec + implementation plan
```

## Reproducibility check

```bash
make recreate   # should return to the same 3-node Ready state
```

## OpenTelemetry collection → ClickHouse Cloud

Once the cluster is up, deploy the OTel pipeline that ships **logs, metrics, and traces**
to ClickHouse Cloud (viewed in the Cloud's built-in HyperDX UI). Architecture:

```
otel-demo ns:     OTel Demo + its bundled collector ─┐ OTLP
observability ns: DaemonSet agent (logs + node/pod metrics) ─┤
                  Deployment agent (events + cluster metrics) ─┤
                                                              ▼
                  GATEWAY (ClickStack collector) ── clickhouse exporter ──▶ ClickHouse Cloud
```

The **gateway** is the only component with ClickHouse credentials and the only one that
talks to Cloud. Both agents and the demo send OTLP to it.

### Prerequisites
- Cluster running (`make up`).
- A ClickHouse Cloud service with ClickStack/HyperDX enabled.
- `.env` filled with `CLICKHOUSE_ENDPOINT`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`,
  and `OTEL_GATEWAY_ENDPOINT` (see `.env.example`). The gateway auto-creates the schema.

### Option 1 — scripted (recommended)
```bash
cp .env.example .env          # fill in CLICKHOUSE_ENDPOINT + CLICKHOUSE_PASSWORD
make demo-images              # build the 19 demo images for this arch (~12 min, once)
make otel-up                  # gateway → agents → demo (idempotent)
make otel-status              # all workloads
make otel-down                # remove the pipeline (keeps the cluster)
```

### The demo and its failure scenarios

The demo is deployed from **ClickHouse's fork of the OpenTelemetry Demo**, not the upstream
Helm chart. `otel-demo/upstream/opentelemetry-demo.yaml` is a verbatim copy of the fork's own
Kubernetes manifest, pinned to `CLICKHOUSE_DEMO_FORK_REF`; `otel-demo/kustomization.yaml`
holds our (small) delta; `make otel-up` applies both with `kubectl apply -k otel-demo/`.

**Images are built locally.** The fork publishes **amd64-only** images, which cannot run on
Apple Silicon, so `make demo-images` builds all 19 services from source for your architecture
(`clickstack-local/ch-otel-demo:latest-*`) and loads them into kind. Roughly 12 minutes the
first time, cached afterwards. `make otel-up` refuses to deploy if the images, the vendored
manifest and `.env` disagree about which fork commit they came from.

**Failure scenarios come from the fork's flagd defaults** — `paymentCacheLeak` is on, which
produces the ClickStack walkthrough's incident (`Visa cache full: cannot add new item.` →
`Failed to place order`) continuously. There is no `SCENARIOS` variable; to change flags at
runtime, use the flagd UI:

```bash
kubectl -n otel-demo port-forward deploy/flagd 4000:4000   # then open http://localhost:4000
```

The overlay sets the payment cache to 10 entries (the manifest ships 100000, at which the
incident never fires), so expect a minute or two of checkout traffic before it starts throwing.
Two load generators drive the store: the Locust API user, and an artillery scenario that runs a
real Chromium browser through the storefront.

**Upgrading the fork:** bump `CLICKHOUSE_DEMO_FORK_REF` in `.env`, run
`scripts/refresh-demo-manifest.sh` (re-vendors the manifest — review the `git diff`), then
`make demo-images`.

> To walk through the demo end-to-end you also need the HyperDX **data sources** configured —
> see [Replicate the ClickStack walkthrough](#replicate-the-clickstack-walkthrough) below.

### Replicate the ClickStack walkthrough

The ClickStack
[remote-demo walkthrough](https://clickhouse.com/docs/use-cases/observability/clickstack/getting-started/remote-demo-data)
reads **four HyperDX data sources** — Logs, Traces, Metrics, Sessions. Two things are
required to follow it against **your own** stack (steps 1–13):

**1. Generate the data** — the incident is on by default:
```bash
make demo-images && make otel-up             # fork images; paymentCacheLeak is a flagd default
```
This produces the `Failed to place order` frontend log (step 6), the failing checkout
**traces** (step 8) — the log carries a `TraceId`, so its `Trace` button works — and the
`visa_validation_cache.size` gauge for step 13. (The infra **metrics** for steps 7/10 are
already collected.)

**2. Configure the HyperDX sources** — the ClickStack collector auto-creates the ClickHouse
*tables*, but HyperDX *sources* (which point HyperDX at those tables and correlate them) are
**not** auto-created for your own ClickHouse. This is why "view a trace" and the metrics view
are missing until you configure them.
```bash
make hyperdx-sources                          # prints readiness + exact source settings
make hyperdx-sources APPLY=1                   # also attempts to create them via the Cloud API
```
For **Managed ClickStack** (ClickHouse Cloud), `APPLY=1` uses the ClickHouse Cloud API
(`https://api.clickhouse.cloud/v1/organizations/<ORG>/services/<SERVICE>/clickstack/...`,
HTTP Basic auth). Set in `.env`: `CLICKHOUSE_CLOUD_ORG_ID`, `CLICKHOUSE_CLOUD_SERVICE_ID`,
and a Cloud API key (`CLICKHOUSE_CLOUD_API_KEY_ID` / `_SECRET` from **Organization settings →
API keys**, needing the *Manage ClickStack API* permission). The source-**create** endpoints
are **Beta**, so if `APPLY` doesn't create them, configure them by hand (the reliable path) in
the hosted HyperDX UI → **Team Settings → Sources**, all pointing at your `default` database:

| Source | Kind | Table(s) | Key fields |
|--------|------|----------|-----------|
| Logs | Log | `otel_logs` | Timestamp=`Timestamp`, Trace Id=`TraceId`, Span Id=`SpanId`, **Correlated Trace Source = Traces** |
| Traces | Trace | `otel_traces` | Timestamp=`Timestamp`, Trace Id=`TraceId`, Span Id=`SpanId` |
| Metrics | Metric | `otel_metrics_gauge` / `otel_metrics_sum` / `otel_metrics_histogram` | (default OTel schema) |
| Sessions | Session | `hyperdx_sessions` | (populated only with browser RUM — see below) |

The **Correlated Trace Source** on the Logs source is what makes the `Trace` button appear on
a log (step 8). With the default OpenTelemetry schema HyperDX infers the column mappings.

> **Why the fork services need `HYPERDX_API_KEY`.** Both the fork `frontend` and `payment`
> initialise telemetry through `@hyperdx/node-opentelemetry`, whose `init()` **hard-returns
> unless an api key is in the environment** ("OpenTelemetry SDK initialization skipped"). With
> it skipped they emit **no spans and no app metrics**, and their logs carry an empty
> `TraceId` — so no `Trace` button (step 8) and no cache gauge (step 13), no matter how the
> sources are configured. The SDK also exports OTLP over **HTTP** while the chart points
> `OTEL_EXPORTER_OTLP_ENDPOINT` at the collector's **gRPC** port, so the per-signal
> `OTEL_EXPORTER_OTLP_{TRACES,LOGS,METRICS}_ENDPOINT` vars redirect it to `:4318`. All of this
> is handled in `otel/otel-demo-visa-cache-values.yaml`; the key is only sent as an
> `Authorization` header and our own collector doesn't authenticate it.

**Known limitations (tracked as GitHub issues):**
- **Session replay (steps 14–15)** is not yet included — it needs browser RUM (the fork
  frontend's HyperDX browser SDK wired to an ingestion endpoint, a Playwright browser-traffic
  driver, and the Sessions source populated).

### Option 2 — raw helm/kubectl
Either path works — the scripts just codify these commands. With `.env` loaded
(`set -a; . ./.env; set +a`) and kubeconfig exported (`eval "$(make -s kubeconfig)"`):

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# namespaces
kubectl create namespace observability
kubectl create namespace otel-demo

# credentials Secret + gateway-endpoint ConfigMap
kubectl create secret generic clickhouse-credentials -n observability \
  --from-literal=CLICKHOUSE_ENDPOINT="$CLICKHOUSE_ENDPOINT" \
  --from-literal=CLICKHOUSE_USER="$CLICKHOUSE_USER" \
  --from-literal=CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD"
kubectl create configmap otel-config-vars -n observability \
  --from-literal=YOUR_OTEL_COLLECTOR_ENDPOINT="$OTEL_GATEWAY_ENDPOINT"

# gateway → agents
helm install clickstack-gateway open-telemetry/opentelemetry-collector -n observability -f otel/gateway-values.yaml
helm install otel-agent   open-telemetry/opentelemetry-collector -n observability -f otel/k8s-daemonset-values.yaml
helm install otel-cluster open-telemetry/opentelemetry-collector -n observability -f otel/k8s-deployment-values.yaml

# demo (the fork's manifest + our overlay; images must be built first)
scripts/build-demo-images.sh
kubectl apply -k otel-demo/
```

### Access the demo UI on localhost:8080

The cluster reserves host ports `8080 -> :80` (see the layout table) for an ingress
controller. Deploy [ingress-nginx](https://kind.sigs.k8s.io/docs/user/ingress/) plus
an `Ingress` that routes to the demo's `frontend-proxy`, and the storefront is served
on your Mac:

```bash
make ingress-up       # run AFTER make otel-up (the Ingress targets frontend-proxy)
open http://localhost:8080
make ingress-status   # controller pod + Ingress
make ingress-down     # remove the controller + Ingress (keeps the cluster)
```

How it works: kind publishes host `8080 -> control-plane node :80`. ingress-nginx
binds `hostPort` 80, so `scripts/deploy-ingress.sh` pins the controller to the
control-plane node (the one with the port mapping) and applies
[ingress/frontend-ingress.yaml](ingress/frontend-ingress.yaml). Traffic flows:
`localhost:8080 -> node :80 -> nginx -> frontend-proxy -> demo UI`.

> The ingress-nginx version is pinned in `scripts/deploy-ingress.sh`. k8s v1.36.1 is
> newer than any ingress-nginx release officially tests against, so the script waits
> for the controller to reach `Ready` and verifies `localhost:8080` returns `200`;
> bump the pin if it ever fails to come up.

### Verify the gateway connected to Cloud
```bash
kubectl -n observability logs deploy/clickstack-gateway-opentelemetry-collector \
  | grep -iE "clickhouse|seed|error"
# expect: "Successfully connected to ClickHouse" and "Schema seed completed", no errors
```

### Notes / gotchas
- **Agent image must match the chart appVersion** (`0.154.0` here). The
  `kubernetesAttributes` preset emits config keys (e.g. `otel_annotations`) that older
  collector images reject — a mismatch crash-loops the agents.
- The DaemonSet agent has a **control-plane toleration** so it runs on all 3 nodes.
- **The demo images must be built locally** — the fork publishes amd64 only, so
  `make demo-images` builds all 19 for your architecture and `kind load`s them. The overlay
  retargets the image name to `clickstack-local/ch-otel-demo`, which exists on no registry,
  so nothing can accidentally pull the amd64 originals back over them.
- **Two source patches are applied to the fork clone at build time** (never to the vendored
  manifest), and both fail loudly if they stop applying: `accounting`'s
  `TreatWarningsAsErrors` — its `NuGetAudit` runs at level `low`, so OpenTelemetry advisories
  published after the pinned commit turn into build errors, which breaks on amd64 too — and
  the artillery Dockerfile, whose `artilleryio/artillery` base is amd64-only on every tag.
- **There is no demo collector.** The fork's design has apps export straight to the ClickStack
  collector, so an `ExternalName` Service aliases `my-clickstack-otel-collector` to our
  gateway. A consequence: no spanmetrics — HyperDX derives service health from traces. If we
  ever want spanmetrics, it belongs in the gateway, not the demo.
- **`scripts/check-overlay.sh` runs on every deploy** and asserts the overlay's invariants
  (19 local images, no `Always` pull policies, `CACHE_SIZE=10`, Jaeger removed, alias and
  secret present), so a fork refresh that silently drops one is caught before it becomes a
  crash-looping pod.

## Reproducibility check

```bash
make recreate    # cluster: same 3-node Ready state
make otel-up     # redeploy the full pipeline
make ingress-up  # re-expose the demo UI on localhost:8080
```
