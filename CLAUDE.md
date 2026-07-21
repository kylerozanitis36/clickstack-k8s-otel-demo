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
  Commands: `make otel-up`/`otel-down`/`otel-status`/`otel-scenarios`.

### Failure scenarios (feature flags)
`make otel-up` enables a selectable set of the demo's built-in failure scenarios
(flagd feature flags) so the pipeline continuously emits real error patterns. The
Locust load generator ships enabled by default; only the failure flags are toggled.
- `make otel-up` → default `paymentFailure=25%` only (the checkout charge-failure /
  `Failed to place order` incident, without extra product-catalog/recommendation noise).
- `make otel-up SCENARIOS=none` → no failures (healthy demo).
- `make otel-up SCENARIOS="flag[=variant] ..."` → exactly those flags (bare flag →
  `on`, `paymentFailure` bare → `25%`); unknown flags/variants fail loudly.
- `make otel-scenarios` → list the flag catalog + variants.
- Mechanism: the demo chart bakes the flag catalog into a static file with **no Helm
  override**, so `scripts/deploy-otel.sh` pulls the chart, delta-patches the selected
  flags' `defaultVariant` into its **own** `flagd-config-scenarios` ConfigMap (flagd
  mounts it via a `components.flagd.additionalVolumes` override in
  `otel-demo-values.yaml`; the chart's own `flagd-config` is left untouched to avoid a
  Helm server-side-apply field-ownership conflict), then — **only when the selection
  changed vs the running cluster** — restarts flagd **and its flag-consuming services**.
  flagd reads the flag file only at startup, and its consumers (product-catalog,
  recommendation, payment, cart, …) hold their flagd connection and keep serving the
  PREVIOUS flags if only flagd restarts, so both must roll for a scenario change to take
  effect. A fresh install needs no restarts (Helm starts flagd + consumers together with
  the right flags). Idempotent; self-heals on chart upgrades.
  Design: [docs/superpowers/specs/2026-07-15-configurable-failure-scenarios-design.md](docs/superpowers/specs/2026-07-15-configurable-failure-scenarios-design.md).
- **The ClickStack `remote-demo-data` walkthrough is not reproducible on this stock
  demo.** Its `Visa cache full: cannot add new item` / `Failed to place order` incident
  comes from ClickHouse's **fork** (`ClickHouse/opentelemetry-demo`, `paymentCacheLeak`
  flag) captured into a pre-recorded dataset on `sql.clickhouse.com`. The upstream OTel
  demo (any version, incl. `main`) instead throws `Payment request failed. Invalid
  token. app.loyalty.level=gold`. To match the walkthrough live, self-host the ClickHouse
  fork; otherwise adapt the walkthrough to the stock errors (checkout `PlaceOrder` →
  `failed to charge card`).

### Gotchas (learned during setup)
- Agent collector image tag **must match the helm chart's appVersion** (`0.154.0`); the
  `kubernetesAttributes` preset emits config keys older images reject (crash loop).
- `otel/otel-demo-values.yaml` nulls the demo collector's hostPorts (the cluster `otel-agent`
  DaemonSet already binds them) and disables the flagd-ui sidecar (OOMs at 250Mi).
- **Demo collector infra presets disabled** (`opentelemetry-collector.presets.hostMetrics/
  kubeletMetrics/clusterMetrics: false`). The demo's bundled collector otherwise scrapes
  host/kubelet/cluster metrics — redundant with our `otel-agent`/`otel-cluster` (double-
  counted infra metrics) and its kubeletstats uses `${env:K8S_NODE_IP}:10250` with no
  `insecure_skip_verify`, flooding logs with `cannot validate certificate … doesn't
  contain any IP SANs` (kind's kubelet cert has no IP SANs). Disabling leaves the demo
  collector forwarding only app telemetry to the gateway.
- **Browser-traffic Locust user is disabled** (`LOCUST_BROWSER_TRAFFIC_ENABLED=false` via
  `components.load-generator.envOverrides`). In demo image 2.2.0 it crashes on every task
  (`AttributeError: 'WebsiteBrowserUser' object has no attribute 'tracer'`) — upstream
  locustfile bug: `PlaywrightUser.__init__` shallow-copies the user into `sub_users` (which
  run the tasks) *before* the subclass sets `self.tracer`. It's not config-fixable in the
  image and only added 100%-failing noise; the API `WebsiteUser` reliably drives the
  checkout/payment failures. Re-enabling needs a patched locustfile or a fixed image tag.

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
