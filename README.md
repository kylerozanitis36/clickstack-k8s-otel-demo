# clickstack-k8s-otel-demo

Run a lightweight, multi-node Kubernetes cluster locally on macOS, as the foundation
for collecting logs, metrics, and traces with an OpenTelemetry collector and shipping
them to ClickHouse Cloud / ClickStack (HyperDX).

This repo currently covers **step 1: hosting the cluster locally**. The cluster uses
[kind](https://kind.sigs.k8s.io/) (Kubernetes-in-Docker) and is fully declarative so
colleagues can recreate the exact same cluster from checked-in config.

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
| `make status`     | Show nodes and all pods                      |
| `make kubeconfig` | Print the `export KUBECONFIG=...` line       |

## How it works

- [`.env`](.env.example) holds the cluster name, pinned node image, kubeconfig path, and
  (for phase 2) the ClickHouse Cloud endpoint/credentials + gateway endpoint.
- [`kind/cluster-config.yaml`](kind/cluster-config.yaml) is a template; `scripts/create-cluster.sh`
  renders it with `envsubst` and feeds it to `kind`.
- [`scripts/preflight.sh`](scripts/preflight.sh) checks Docker is running and installs missing tools.
- [`otel/`](otel/) holds the Helm values for the OpenTelemetry pipeline (see below).

### Repository layout
```
.env(.example)            cluster + ClickHouse Cloud config (.env is gitignored)
Makefile                  make up/down/status/kubeconfig + otel-up/otel-down/otel-status
kind/cluster-config.yaml  kind cluster manifest (template)
otel/                     OpenTelemetry Helm values:
  gateway-values.yaml       gateway → ClickHouse Cloud (the only egress)
  k8s-daemonset-values.yaml per-node agent: logs + host/kubelet metrics
  k8s-deployment-values.yaml single agent: k8s events + cluster metrics
  otel-demo-values.yaml      OTel Demo, routed to the gateway (envsubst template)
scripts/                  create/delete cluster + deploy/teardown OTel
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

## Reproducibility check

```bash
make recreate    # cluster: same 3-node Ready state
make otel-up     # redeploy the full pipeline
```
