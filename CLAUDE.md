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
- Control-plane reserves host ports `8080->:80` and `8443->:443` for a future ingress controller.
- kind nodes already expose `/var/log/pods` + `/var/log/containers`, so a future OTel DaemonSet can
  hostPath-mount them with no extra cluster config.

### Common commands
- `cp .env.example .env` — one-time setup (`.env` is gitignored).
- `make up` / `make down` / `make recreate` — create / delete / rebuild the cluster (idempotent).
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
- **OTel Demo** (`otel-demo` ns) generates traces; its bundled collector forwards to the gateway.
- Values files live in `otel/`: `gateway-values.yaml`, `k8s-daemonset-values.yaml`,
  `k8s-deployment-values.yaml`, `otel-demo-values.yaml` (template rendered with envsubst).
  Commands: `make otel-up`/`otel-down`/`otel-status`.

### Gotchas (learned during setup)
- Agent collector image tag **must match the helm chart's appVersion** (`0.154.0`); the
  `kubernetesAttributes` preset emits config keys older images reject (crash loop).
- `otel/otel-demo-values.yaml` nulls the demo collector's hostPorts (the cluster `otel-agent`
  DaemonSet already binds them) and disables the flagd-ui sidecar (OOMs at 250Mi).

## Status / Next Steps
Done: local cluster hosting (phase 1) + OTel collection into ClickHouse Cloud (phase 2).
Possible next: dashboards/alerts in HyperDX, sampling/retention tuning, or app-level
instrumentation beyond the demo.
