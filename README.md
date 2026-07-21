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
Makefile                  make up/down/recreate/pause/resume/status/kubeconfig + otel-up/otel-down/otel-status/otel-scenarios
kind/cluster-config.yaml  kind cluster manifest (template)
otel/                     OpenTelemetry Helm values:
  gateway-values.yaml       gateway → ClickHouse Cloud (the only egress)
  k8s-daemonset-values.yaml per-node agent: logs + host/kubelet metrics
  k8s-deployment-values.yaml single agent: k8s events + cluster metrics
  otel-demo-values.yaml      OTel Demo, routed to the gateway (envsubst template)
ingress/frontend-ingress.yaml  Ingress exposing the demo UI on localhost:8080
scripts/                  create/delete/pause/resume cluster + deploy/teardown OTel + ingress
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
make otel-up                  # gateway → agents → demo (idempotent)
make otel-status              # all workloads
make otel-down                # remove the pipeline (keeps the cluster)
```

### Failure scenarios (always-on error patterns)

The demo ships a Locust load generator (already running) plus a set of built-in
failure scenarios controlled by [flagd](https://flagd.dev) feature flags — off by
default. `make otel-up` turns a selectable set of them **on** so the pipeline
continuously produces real error patterns (failing traces, error-rate spikes,
correlated infra metrics) for a live, always-fresh demo.

```bash
make otel-up                                   # default: paymentFailure=25% (payment incident only)
make otel-up SCENARIOS=none                     # clean/healthy demo, no failures
make otel-up SCENARIOS="paymentFailure=50% kafkaQueueProblems=on"   # custom
make otel-scenarios                             # list every flag + its variants
```

- **Default** (bare `make otel-up`): `paymentFailure=25%` — ~1 in 4 checkouts fails at
  the charge step (checkout `PlaceOrder` → `failed to charge card`), the payment-incident
  story, without extra product-catalog/recommendation noise. Add more via `SCENARIOS`.
- **`SCENARIOS=none`**: all failure flags stay off.
- **`SCENARIOS="flag[=variant] ..."`**: exactly those flags. A bare flag → its `on`
  variant; `paymentFailure` bare → `25%`. Unknown flags/variants fail loudly with the
  valid options. Run `make otel-scenarios` to see the catalog.

> The demo chart bakes the flag catalog into a static file with no Helm override, so
> `deploy-otel.sh` delta-patches the selection into its own `flagd-config-scenarios`
> ConfigMap, which `flagd` mounts via a values override (leaving the chart's
> `flagd-config` untouched to avoid a Helm field-ownership conflict), then restarts
> `flagd` (which only reads the file at startup). Idempotent, and self-heals on chart
> upgrades — it encodes only the selected delta, never a full copy.

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

# demo (render the gateway endpoint into the values first)
envsubst '${OTEL_GATEWAY_ENDPOINT}' < otel/otel-demo-values.yaml > otel/.otel-demo-values.rendered.yaml
helm install otel-demo open-telemetry/opentelemetry-demo -n otel-demo -f otel/.otel-demo-values.rendered.yaml
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
- `otel/otel-demo-values.yaml` **nulls the demo collector's hostPorts** (the cluster
  agent already binds them) and **disables the flagd-ui sidecar** (it OOMs at 250Mi
  and isn't needed).
- **Failure-scenario flags live in a static file baked into the demo chart** (no Helm
  value overrides them), so `deploy-otel.sh` delta-patches the selection into its own
  `flagd-config-scenarios` ConfigMap (flagd mounts it via a values override; the
  chart's `flagd-config` is left alone to avoid a Helm field-ownership conflict) and
  **restarts flagd** — flagd reads the flag file only at startup. See
  [Failure scenarios](#failure-scenarios-always-on-error-patterns) and
  `make otel-scenarios`.
- **The Playwright browser-traffic Locust user is disabled**
  (`LOCUST_BROWSER_TRAFFIC_ENABLED=false`). In demo image 2.2.0 it crashes on every task
  (`'WebsiteBrowserUser' object has no attribute 'tracer'`, an upstream locustfile bug),
  adding only 100%-failing noise. The API load user still drives all the
  browse/cart/checkout traffic, so the failure scenarios above work as expected.

## Reproducibility check

```bash
make recreate    # cluster: same 3-node Ready state
make otel-up     # redeploy the full pipeline
make ingress-up  # re-expose the demo UI on localhost:8080
```
