# OTel → ClickStack Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **STATUS: COMPLETED 2026-06-28.** All 9 tasks done and verified end-to-end. The
> as-built result differs from the original steps in a few places (see "As-built
> deviations" immediately below); the original task text is kept for the execution record.

## As-built deviations (read first)

- **Helm values live in `otel/`**, not the repo root. Every `-f <name>-values.yaml` below is
  actually `-f otel/<name>-values.yaml`; the demo render target is `otel/.otel-demo-values.rendered.yaml`.
- **Agent image is `0.154.0`, not `0.123.0`** (Task 5). It must match the opentelemetry-collector
  chart appVersion (chart `0.159.1`); the `kubernetesAttributes` preset emits `otel_annotations`,
  which `0.123.0` rejects → crash loop. Gateway image unchanged (`clickstack-otel-collector:2.19.0`).
- **DaemonSet gained a control-plane toleration** (Task 5) so it runs on all 3 nodes.
- **`otel/otel-demo-values.yaml` adds two fixes** (Task 6): nulls the demo collector's hostPorts
  (the cluster agent already binds them → Pending pods otherwise) and disables the flagd-ui
  sidecar (OOMs at 250Mi). Demo chart `0.40.9`.
- **Gateway Option A worked** (Task 4) — baked-in ClickHouse pipeline seeded the schema and
  connected; the fallback in Task 4 Step 5 was not needed.

---

**Goal:** Deploy an OpenTelemetry collection pipeline on the local `kind` cluster that ships logs, metrics, and traces into ClickHouse Cloud, viewable in the Cloud's built-in HyperDX UI.

**Architecture:** Two in-cluster OTel agents (a per-node DaemonSet for logs + node/pod metrics, a single-replica Deployment for k8s events + cluster metrics) and a deployed OpenTelemetry Demo all send OTLP to a single **gateway** collector (ClickStack distribution image), which is the only component that exports to ClickHouse Cloud. Agents/gateway live in `observability`; the demo lives in `otel-demo`.

**Tech Stack:** Helm (upstream `open-telemetry/opentelemetry-collector` + `open-telemetry/opentelemetry-demo` charts), the ClickStack collector image, `kubectl`, `envsubst`, the existing `.env` + `scripts/` + `Makefile` workflow.

## Global Constraints

- Gateway Helm release name is **`clickstack-gateway`** (load-bearing — its Service `clickstack-gateway-opentelemetry-collector` is the OTLP target for all senders). Other release names: `otel-agent`, `otel-cluster`, `otel-demo`.
- In-cluster gateway endpoint (used by agents + demo): `http://clickstack-gateway-opentelemetry-collector.observability.svc.cluster.local:4318` (FQDN so it resolves cross-namespace).
- ClickHouse credentials are **never committed**: stored in `.env` (gitignored), injected as a k8s Secret `clickhouse-credentials` in `observability`. Use the **`default`** ClickHouse user.
- Agent collector image: **`otel/opentelemetry-collector-contrib:0.154.0`** (must match the chart appVersion; see As-built deviations). Gateway image: `docker.clickhouse.com/clickhouse/clickstack-otel-collector:2.19.0`.
- Helm values files live under **`otel/`** (e.g. `otel/gateway-values.yaml`).
- Namespaces: `observability` (gateway + agents), `otel-demo` (demo).
- Git commits are **deferred** (user is handling git separately) — do not add commit steps; a note at the end covers eventual commit.
- `kubectl` context must be `kind-clickstack-local`; export the project-local kubeconfig first: `eval "$(make -s kubeconfig)"`.

---

### Task 1: Extend `.env` / `.env.example` and `.gitignore`

**Files:**
- Modify: `.env.example`
- Modify: `.env` (local, gitignored)
- Modify: `.gitignore`

**Interfaces:**
- Produces: env vars `CLICKHOUSE_ENDPOINT`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `OTEL_GATEWAY_ENDPOINT` consumed by Tasks 3, 4, 6, 7.

- [ ] **Step 1: Append the OTel/ClickHouse block to `.env.example`**

```dotenv

# --- OpenTelemetry → ClickHouse Cloud (phase 2) ---
# ClickHouse Cloud HTTPS endpoint (native secure port 8443).
CLICKHOUSE_ENDPOINT=https://CHANGE_ME.clickhouse.cloud:8443
# Using the default user for now (see design doc).
CLICKHOUSE_USER=default
# Set in .env only — never commit a real password.
CLICKHOUSE_PASSWORD=CHANGE_ME
# In-cluster gateway OTLP/HTTP endpoint (FQDN; senders live in multiple namespaces).
OTEL_GATEWAY_ENDPOINT=http://clickstack-gateway-opentelemetry-collector.observability.svc.cluster.local:4318
```

- [ ] **Step 2: Mirror the block into `.env`, filling real values**

Copy the same four keys into `.env`, setting the real `CLICKHOUSE_ENDPOINT` (the host from `gateway-values.yaml`, `https://fv0nc8qsjy.us-west-2.aws.clickhouse.cloud:8443`) and the real `CLICKHOUSE_PASSWORD`. Leave `CLICKHOUSE_USER=default`.

- [ ] **Step 3: Add rendered-file ignores to `.gitignore`**

Add this line under the existing kind ignore:

```
# Rendered helm values (generated from *.yaml templates with envsubst)
*.rendered.yaml
```

- [ ] **Step 4: Verify env loads and all four vars are set**

Run:
```bash
set -a; . ./.env; set +a
for v in CLICKHOUSE_ENDPOINT CLICKHOUSE_USER CLICKHOUSE_PASSWORD OTEL_GATEWAY_ENDPOINT; do
  [ -n "${!v:-}" ] && echo "$v OK" || echo "$v MISSING"
done
```
Expected: four `... OK` lines, none `MISSING`.

---

### Task 2: Add and update Helm repositories

**Files:** none (repo-level Helm state).

**Interfaces:**
- Produces: Helm repos `open-telemetry` available for Tasks 4, 5, 6.

- [ ] **Step 1: Add the OpenTelemetry Helm repo and update**

Run:
```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

- [ ] **Step 2: Verify the charts are visible**

Run:
```bash
helm search repo open-telemetry/opentelemetry-collector open-telemetry/opentelemetry-demo
```
Expected: both `open-telemetry/opentelemetry-collector` and `open-telemetry/opentelemetry-demo` listed with a version/app-version.

---

### Task 3: Create namespaces, the ClickHouse Secret, and the gateway-endpoint ConfigMap

**Files:** none yet (these exact commands are codified into `scripts/deploy-otel.sh` in Task 7).

**Interfaces:**
- Consumes: env vars from Task 1.
- Produces: namespaces `observability`, `otel-demo`; Secret `clickhouse-credentials` and ConfigMap `otel-config-vars` (key `YOUR_OTEL_COLLECTOR_ENDPOINT`) in `observability` — consumed by Tasks 4 and 5.

- [ ] **Step 1: Load env and create namespaces (idempotent)**

Run:
```bash
set -a; . ./.env; set +a
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace otel-demo --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 2: Create the ClickHouse credentials Secret (idempotent)**

Run:
```bash
kubectl create secret generic clickhouse-credentials \
  --namespace observability \
  --from-literal=CLICKHOUSE_ENDPOINT="$CLICKHOUSE_ENDPOINT" \
  --from-literal=CLICKHOUSE_USER="$CLICKHOUSE_USER" \
  --from-literal=CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 3: Create the gateway-endpoint ConfigMap (idempotent)**

Run:
```bash
kubectl create configmap otel-config-vars \
  --namespace observability \
  --from-literal=YOUR_OTEL_COLLECTOR_ENDPOINT="$OTEL_GATEWAY_ENDPOINT" \
  --dry-run=client -o yaml | kubectl apply -f -
```

- [ ] **Step 4: Verify Secret and ConfigMap exist with the right keys**

Run:
```bash
kubectl -n observability get secret clickhouse-credentials -o jsonpath='{.data}' | tr ',' '\n'
kubectl -n observability get configmap otel-config-vars -o jsonpath='{.data.YOUR_OTEL_COLLECTOR_ENDPOINT}'; echo
```
Expected: secret shows keys `CLICKHOUSE_ENDPOINT`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`; configmap prints the FQDN gateway endpoint.

---

### Task 4: Wire and deploy the gateway (Option A), with verification gate

**Files:**
- Modify: `gateway-values.yaml`

**Interfaces:**
- Consumes: Secret `clickhouse-credentials` (Task 3).
- Produces: Service `clickstack-gateway-opentelemetry-collector` on port 4318 (OTLP/HTTP) and 4317 (OTLP/gRPC) in `observability` — the OTLP target for Tasks 5 and 6.

- [ ] **Step 1: Replace the hardcoded `extraEnvs` in `gateway-values.yaml` with Secret references**

Replace the `extraEnvs:` block (lines 27-33, the `CLICKHOUSE_*` literals) with:

```yaml
extraEnvs:
  - name: CLICKHOUSE_ENDPOINT
    valueFrom:
      secretKeyRef:
        name: clickhouse-credentials
        key: CLICKHOUSE_ENDPOINT
  - name: CLICKHOUSE_USER
    valueFrom:
      secretKeyRef:
        name: clickhouse-credentials
        key: CLICKHOUSE_USER
  - name: CLICKHOUSE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: clickhouse-credentials
        key: CLICKHOUSE_PASSWORD
```

Leave `mode`, `image`, and `ports` (otlp + otlp-http enabled) unchanged. Do **not** add a `config:` block — Option A relies on the ClickStack image's baked-in ClickHouse pipeline.

- [ ] **Step 2: Install the gateway**

Run:
```bash
helm install clickstack-gateway open-telemetry/opentelemetry-collector \
  --namespace observability \
  -f gateway-values.yaml
```

- [ ] **Step 3: Wait for the gateway pod to be Ready**

Run:
```bash
kubectl -n observability rollout status deploy/clickstack-gateway-opentelemetry-collector --timeout=120s
```
Expected: `deployment ... successfully rolled out`.

- [ ] **Step 4: VERIFICATION GATE — confirm the ClickHouse exporter loaded and connected**

Run:
```bash
kubectl -n observability logs deploy/clickstack-gateway-opentelemetry-collector | grep -iE "clickhouse|exporter|error|refused|auth" | head -40
```
Expected: log lines showing the `clickhouse` exporter starting; **no** auth/TLS/connection-refused errors. The Service should expose 4317/4318:
```bash
kubectl -n observability get svc clickstack-gateway-opentelemetry-collector
```

- [ ] **Step 5: If the gate fails (baked-in config was overridden by the chart)**

Symptom: logs show only a default config / no `clickhouse` exporter, or `--config` points at the chart ConfigMap. Apply the fallback — add an explicit ClickHouse pipeline to `gateway-values.yaml` under `config:` using env-substituted vars, e.g.:

```yaml
config:
  receivers:
    otlp:
      protocols:
        grpc: {}
        http: {}
  exporters:
    clickhouse:
      endpoint: "${env:CLICKHOUSE_ENDPOINT}"
      username: "${env:CLICKHOUSE_USER}"
      password: "${env:CLICKHOUSE_PASSWORD}"
      database: default
  service:
    pipelines:
      logs: { receivers: [otlp], exporters: [clickhouse] }
      metrics: { receivers: [otlp], exporters: [clickhouse] }
      traces: { receivers: [otlp], exporters: [clickhouse] }
```
Then `helm upgrade clickstack-gateway open-telemetry/opentelemetry-collector -n observability -f gateway-values.yaml` and re-run Step 4. (Alternative escalation: redeploy the gateway release using the dedicated `ClickHouse/ClickStack-helm-charts` chart; agents/demo are unaffected.)

---

### Task 5: Fix and deploy both agents

**Files:**
- Modify: `k8s-daemonset-values.yaml`
- Verify only: `k8s-deployment-values.yaml`

**Interfaces:**
- Consumes: ConfigMap `otel-config-vars` (Task 3), gateway Service (Task 4).
- Produces: a DaemonSet pod per node + a single Deployment-agent pod sending OTLP to the gateway.

- [ ] **Step 1: Fix the `extraEnvs` placeholder bug in `k8s-daemonset-values.yaml`**

Replace the broken block (lines 40-45, which use `<YOUR_OTEL_COLLECTOR_ENDPOINT>` with angle brackets) with:

```yaml
extraEnvs:
  - name: YOUR_OTEL_COLLECTOR_ENDPOINT
    valueFrom:
      configMapKeyRef:
        name: otel-config-vars
        key: YOUR_OTEL_COLLECTOR_ENDPOINT
```

- [ ] **Step 2: Confirm `k8s-deployment-values.yaml` already references the ConfigMap correctly**

Open `k8s-deployment-values.yaml` and confirm its `extraEnvs` uses `name: YOUR_OTEL_COLLECTOR_ENDPOINT` and `configMapKeyRef` key `YOUR_OTEL_COLLECTOR_ENDPOINT` (no angle brackets). No change expected.

- [ ] **Step 3: Install the DaemonSet agent (logs + node/pod metrics)**

Run:
```bash
helm install otel-agent open-telemetry/opentelemetry-collector \
  --namespace observability \
  -f k8s-daemonset-values.yaml
```

- [ ] **Step 4: Install the Deployment agent (events + cluster metrics)**

Run:
```bash
helm install otel-cluster open-telemetry/opentelemetry-collector \
  --namespace observability \
  -f k8s-deployment-values.yaml
```

- [ ] **Step 5: Verify both agents are Running (DaemonSet on every node)**

Run:
```bash
kubectl -n observability get pods -l app.kubernetes.io/name=opentelemetry-collector -o wide
kubectl -n observability rollout status ds/otel-agent-opentelemetry-collector --timeout=120s
```
Expected: 3 `otel-agent-*` pods (one per node) Running, 1 `otel-cluster-*` pod Running, plus the gateway pod.

- [ ] **Step 6: Verify agents reach the gateway (no export errors)**

Run:
```bash
kubectl -n observability logs ds/otel-agent-opentelemetry-collector | grep -iE "error|refused|connection|exporter" | head -20
```
Expected: no repeating `connection refused` / DNS errors against the gateway endpoint.

---

### Task 6: Deploy the OpenTelemetry Demo and route it to the gateway

**Files:**
- Create: `otel-demo-values.yaml` (template with `${OTEL_GATEWAY_ENDPOINT}`)

**Interfaces:**
- Consumes: gateway Service (Task 4), env var `OTEL_GATEWAY_ENDPOINT` (Task 1).
- Produces: demo workloads in `otel-demo` whose bundled collector forwards traces/metrics/logs to the gateway.

- [ ] **Step 1: Create `otel-demo-values.yaml`**

```yaml
# OpenTelemetry Demo — route the bundled collector to our ClickStack gateway and
# disable bundled backends (our gateway + ClickHouse Cloud are the backend).
# Rendered with envsubst (${OTEL_GATEWAY_ENDPOINT}) before install.
opentelemetry-collector:
  config:
    exporters:
      otlphttp/gateway:
        endpoint: "${OTEL_GATEWAY_ENDPOINT}"
        compression: gzip
    service:
      pipelines:
        traces:
          # keep spanmetrics (arrays are replaced, not merged, by Helm)
          exporters: [spanmetrics, otlphttp/gateway]
        metrics:
          exporters: [otlphttp/gateway]
        logs:
          exporters: [otlphttp/gateway]

jaeger:
  enabled: false
prometheus:
  enabled: false
grafana:
  enabled: false
opensearch:
  enabled: false
```

- [ ] **Step 2: Render and install the demo**

Run:
```bash
set -a; . ./.env; set +a
ENVSUBST="$(command -v envsubst || echo "$(brew --prefix gettext)/bin/envsubst")"
"$ENVSUBST" '${OTEL_GATEWAY_ENDPOINT}' < otel-demo-values.yaml > .otel-demo-values.rendered.yaml
helm install otel-demo open-telemetry/opentelemetry-demo \
  --namespace otel-demo \
  -f .otel-demo-values.rendered.yaml
```

- [ ] **Step 3: Wait for the demo to come up**

Run:
```bash
kubectl -n otel-demo rollout status deploy/otel-demo-frontend --timeout=300s
kubectl -n otel-demo get pods
```
Expected: demo pods (frontend, cart, checkout, load generator, bundled collector, etc.) progressing to Running. (First run pulls many images — allow several minutes.)

- [ ] **Step 4: Verify the demo collector forwards to the gateway**

Run:
```bash
kubectl -n otel-demo logs deploy/otel-demo-otelcol 2>/dev/null | grep -iE "otlphttp|gateway|error|refused" | head -20
```
Expected: the `otlphttp/gateway` exporter present; no repeating connection errors to the gateway FQDN. (The demo collector Deployment name may be `otel-demo-otelcol`; if not, find it via `kubectl -n otel-demo get deploy | grep -i otelcol`.)

---

### Task 7: Orchestration scripts and Makefile targets

**Files:**
- Create: `scripts/deploy-otel.sh`
- Create: `scripts/teardown-otel.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: everything above (codifies the exact commands from Tasks 2-6).
- Produces: `make otel-up`, `make otel-down`, `make otel-status`.

- [ ] **Step 1: Create `scripts/deploy-otel.sh`**

```bash
#!/usr/bin/env bash
# Deploy the full OTel → ClickStack pipeline: gateway → agents → demo.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
: "${CLICKHOUSE_ENDPOINT:?}"; : "${CLICKHOUSE_USER:?}"; : "${CLICKHOUSE_PASSWORD:?}"; : "${OTEL_GATEWAY_ENDPOINT:?}"

scripts/preflight.sh   # ensures docker/kind/kubectl/helm/envsubst

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# Namespaces
for ns in observability otel-demo; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# Secret + ConfigMap
kubectl create secret generic clickhouse-credentials -n observability \
  --from-literal=CLICKHOUSE_ENDPOINT="$CLICKHOUSE_ENDPOINT" \
  --from-literal=CLICKHOUSE_USER="$CLICKHOUSE_USER" \
  --from-literal=CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap otel-config-vars -n observability \
  --from-literal=YOUR_OTEL_COLLECTOR_ENDPOINT="$OTEL_GATEWAY_ENDPOINT" \
  --dry-run=client -o yaml | kubectl apply -f -

# Gateway → agents (helm upgrade --install for idempotency)
helm upgrade --install clickstack-gateway open-telemetry/opentelemetry-collector -n observability -f gateway-values.yaml
kubectl -n observability rollout status deploy/clickstack-gateway-opentelemetry-collector --timeout=120s
helm upgrade --install otel-agent  open-telemetry/opentelemetry-collector -n observability -f k8s-daemonset-values.yaml
helm upgrade --install otel-cluster open-telemetry/opentelemetry-collector -n observability -f k8s-deployment-values.yaml

# Demo (render endpoint via envsubst)
ENVSUBST="$(command -v envsubst || echo "$(brew --prefix gettext)/bin/envsubst")"
"$ENVSUBST" '${OTEL_GATEWAY_ENDPOINT}' < otel-demo-values.yaml > .otel-demo-values.rendered.yaml
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo -n otel-demo -f .otel-demo-values.rendered.yaml

echo "OTel pipeline deployed. Check: make otel-status"
```

- [ ] **Step 2: Create `scripts/teardown-otel.sh`**

```bash
#!/usr/bin/env bash
# Tear down the OTel pipeline (keeps the kind cluster).
set -euo pipefail
cd "$(dirname "$0")/.."

helm uninstall otel-demo -n otel-demo 2>/dev/null || true
helm uninstall otel-agent -n observability 2>/dev/null || true
helm uninstall otel-cluster -n observability 2>/dev/null || true
helm uninstall clickstack-gateway -n observability 2>/dev/null || true
kubectl -n observability delete secret clickhouse-credentials --ignore-not-found
kubectl -n observability delete configmap otel-config-vars --ignore-not-found
kubectl delete namespace otel-demo --ignore-not-found
kubectl delete namespace observability --ignore-not-found
rm -f .otel-demo-values.rendered.yaml
echo "OTel pipeline removed."
```

- [ ] **Step 3: Add Makefile targets**

Append to `Makefile` (use real tabs, and add the targets to the `.PHONY` line):

```makefile
otel-up: ## Deploy the OTel → ClickStack pipeline (gateway, agents, demo)
	@scripts/deploy-otel.sh

otel-down: ## Remove the OTel pipeline (keeps the cluster)
	@scripts/teardown-otel.sh

otel-status: ## Show OTel/demo workloads
	@kubectl -n observability get pods -o wide && echo && kubectl -n otel-demo get pods
```

- [ ] **Step 4: Make scripts executable and verify idempotent re-deploy**

Run:
```bash
chmod +x scripts/deploy-otel.sh scripts/teardown-otel.sh
make otel-status
make otel-up   # should upgrade-in-place without errors (idempotent)
```
Expected: `otel-status` lists gateway + 3 agents + 1 cluster-agent + demo pods; re-running `otel-up` succeeds via `helm upgrade --install`.

---

### Task 8: Documentation (README + CLAUDE.md)

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Add an "OpenTelemetry collection" section to `README.md`**

Document both paths. Scripted:
```bash
cp .env.example .env   # fill in CLICKHOUSE_ENDPOINT + CLICKHOUSE_PASSWORD
make otel-up
make otel-status
```
Raw helm/kubectl (note: "either the scripted path above or these raw commands work"): the namespace + `kubectl create secret`/`configmap` commands from Task 3, the three `helm install` commands from Tasks 4-5, and the envsubst + `helm install otel-demo` from Task 6. Include the gateway verification-gate log check from Task 4 Step 4.

- [ ] **Step 2: Update the "Status / Next Steps" section in `CLAUDE.md`**

Change phase-2 from "Next" to "Done", summarizing: agents + gateway in `observability`, demo in `otel-demo`, credentials via `.env`→Secret, `make otel-up`/`otel-down`/`otel-status`, data viewed in Cloud HyperDX.

- [ ] **Step 3: Verify docs render and commands match reality**

Run:
```bash
grep -n "otel-up\|otel-demo\|clickstack-gateway" README.md CLAUDE.md
```
Expected: references present and consistent with the Makefile targets and release names.

---

### Task 9: End-to-end verification

**Files:** none.

**Interfaces:** confirms the whole pipeline.

- [ ] **Step 1: Confirm all workloads healthy**

Run: `make otel-status`
Expected: gateway (1), `otel-agent` (3, one/node), `otel-cluster` (1), demo pods all Running.

- [ ] **Step 2: SQL sanity check against ClickHouse Cloud**

Run (HTTPS interface; counts the ClickStack tables — adjust names if the deployment uses a different DB/prefix):
```bash
set -a; . ./.env; set +a
for tbl in otel_logs otel_metrics otel_traces; do
  echo -n "$tbl: "
  curl -s "${CLICKHOUSE_ENDPOINT}/?query=SELECT%20count()%20FROM%20${tbl}" \
    -u "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" || echo "(query failed)"
done
```
Expected: non-zero, increasing counts for logs/metrics/traces. (If a table name differs, list tables: `curl -s "${CLICKHOUSE_ENDPOINT}/?query=SHOW%20TABLES" -u "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}"`.)

- [ ] **Step 3: Confirm in HyperDX (Cloud UI)**

In the ClickHouse Cloud built-in HyperDX UI:
- **Logs:** search shows cluster pod logs and `otel-demo` pod logs.
- **Metrics:** `kubeletstats` pod/node CPU & memory and cluster metrics are queryable.
- **Traces:** demo traces appear with a populated service map / span waterfall (e.g. `frontend` → `cartservice` → `checkoutservice`).

- [ ] **Step 4: Reproducibility check**

Run:
```bash
make otel-down
make otel-up
```
Expected: clean teardown, then full redeploy to the same healthy state.

---

## Notes
- **Git is deferred** per the user's instruction. When ready: set a local repo identity, make the initial commit (the repo has no commits yet), and add a GitHub remote/push (requires installing `gh`). The new files to track include `gateway-values.yaml`, `k8s-daemonset-values.yaml`, `k8s-deployment-values.yaml`, `otel-demo-values.yaml`, `scripts/deploy-otel.sh`, `scripts/teardown-otel.sh`, the docs, and Makefile/README/.gitignore changes. `.env`, `.kube/`, and `*.rendered.yaml` stay ignored.
- The gateway verification gate (Task 4, Step 4) is the highest-risk checkpoint — do not proceed to agents/demo until the ClickHouse exporter is confirmed connected.
