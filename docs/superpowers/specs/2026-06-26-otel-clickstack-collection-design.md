# Design: Collecting OpenTelemetry Data from the Local k8s Cluster into ClickHouse Cloud

**Date:** 2026-06-26
**Status:** Implemented (2026-06-28) — see "As-built notes" below
**Phase:** 2 of the `clickstack-k8s-otel-demo` project (phase 1 = local cluster hosting, complete)

## As-built notes (2026-06-28)

Implemented per the plan in `docs/superpowers/plans/2026-06-26-otel-clickstack-collection.md`.
Deviations discovered during execution (also documented in README / CLAUDE.md):

- **Helm values live in `otel/`** (not the repo root): `otel/gateway-values.yaml`,
  `otel/k8s-daemonset-values.yaml`, `otel/k8s-deployment-values.yaml`, `otel/otel-demo-values.yaml`.
- **Chart/image versions:** opentelemetry-collector chart `0.159.1`, opentelemetry-demo chart `0.40.9`.
  Agent image pinned to **`0.154.0`** (the chart's appVersion) — the `kubernetesAttributes`
  preset emits config keys (e.g. `otel_annotations`) that the originally-planned `0.123.0`
  image rejects, crash-looping the agents. **The agent image must track the chart appVersion.**
- **DaemonSet control-plane toleration** added so the agent runs on all 3 nodes (not just workers).
- **OTel Demo collector hostPorts nulled** (the cluster agent already binds 4317/4318/etc. on
  each node) and the **flagd-ui sidecar disabled** (OOMs at its 250Mi default; not needed).
- **Gateway Option A confirmed working** — the ClickStack image's baked-in pipeline ran its
  schema migrate/seed and connected to ClickHouse Cloud; the fallback was not needed.
- Verified end-to-end: logs, metrics (incl. kubeletstats), and demo traces all land in Cloud,
  and a full `make otel-down && make otel-up` reproduces the pipeline with live ingestion.

## Context

Phase 1 stood up a local 3-node `kind` cluster (1 control-plane + 2 workers) on macOS,
backed by Docker Desktop, with a declarative `.env` + `scripts/` + `Makefile` workflow
(see [PLAN.md](../../../PLAN.md) and [CLAUDE.md](../../../CLAUDE.md)).

This phase deploys an OpenTelemetry collection pipeline that ships **logs, metrics, and
traces** from the cluster into an existing **ClickHouse Cloud** service, viewed through
the Cloud's built-in **ClickStack / HyperDX** UI.

Three Helm values files already exist in the repo root, authored from ClickStack docs:
`gateway-values.yaml`, `k8s-daemonset-values.yaml`, `k8s-deployment-values.yaml`. This
design adopts them (with targeted fixes) rather than replacing them.

### Decisions made during brainstorming
- **Signals:** logs + metrics + traces. Traces come from a deployed **OpenTelemetry Demo**.
- **Secrets:** ClickHouse credentials supplied via a **k8s Secret created from `.env`** (nothing secret committed).
- **Destination:** ClickHouse Cloud + ClickStack/HyperDX already provisioned; use the **`default`** user for now; view data in Cloud's built-in HyperDX.
- **Gateway deployment:** **Option A** — keep the ClickStack collector image under the upstream `opentelemetry-collector` Helm chart, with an explicit verification gate + fallback.
- **Deploy UX:** **hybrid** — scripts + Makefile targets *and* documented raw helm/kubectl commands in the README; either path works.

## Architecture

Four tiers, with the gateway as the single egress to ClickHouse Cloud:

```
otel-demo ns:     OTel Demo (astronomy shop) + bundled demo collector ─┐ OTLP
                                                                       │
observability ns: DaemonSet agent (per node)  ─ logs + host/kubelet ───┤ OTLP/HTTP :4318
                  Deployment agent (1 replica) ─ k8s events + cluster ──┤
                                                                       ▼
                  GATEWAY (ClickStack collector image) ── clickhouse exporter ──▶ ClickHouse Cloud
                                                                                  (TLS :8443, default user)
                                                                                  └─ HyperDX UI
```

- **Gateway** is the only component with ClickHouse credentials and the only one talking to Cloud.
- **DaemonSet agent** (`k8s-daemonset-values.yaml`): container logs (filelog), `hostmetrics`, `kubeletstats`, enriched with k8s attributes → gateway.
- **Deployment agent** (`k8s-deployment-values.yaml`, 1 replica to avoid duplication): k8s events + cluster metrics → gateway.
- **OTel Demo's bundled collector** forwards the demo's traces/metrics/logs to our gateway. The DaemonSet additionally captures the demo's pod logs automatically via `/var/log/pods`.

### Namespaces
- `observability` — gateway + both agents (same namespace so agents reach the gateway by short service name).
- `otel-demo` — the OpenTelemetry Demo.

### Component boundaries
| Component | Does | Talks to | Holds secret? |
|-----------|------|----------|---------------|
| Gateway | Receives OTLP, exports to ClickHouse | ClickHouse Cloud | Yes (Secret) |
| DaemonSet agent | Node logs + node/pod metrics | Gateway (OTLP/HTTP) | No |
| Deployment agent | Cluster events + cluster metrics | Gateway (OTLP/HTTP) | No |
| OTel Demo | Generates traces/metrics/logs | Gateway (OTLP) | No |

## Config & Secret Wiring

`.env` (gitignored) gains, with `.env.example` documenting them:
- `CLICKHOUSE_ENDPOINT` — e.g. `https://<host>.clickhouse.cloud:8443`
- `CLICKHOUSE_USER=default`
- `CLICKHOUSE_PASSWORD`
- `OTEL_GATEWAY_ENDPOINT` — in-cluster gateway URL, e.g. `http://clickstack-gateway-opentelemetry-collector:4318`

Deploy-time wiring:
- A script creates k8s Secret **`clickhouse-credentials`** (in `observability`) from the `CLICKHOUSE_*` vars.
- A script creates ConfigMap **`otel-config-vars`** (key `YOUR_OTEL_COLLECTOR_ENDPOINT` = `OTEL_GATEWAY_ENDPOINT`) consumed by both agents.

## Changes to Existing Files

**`gateway-values.yaml`**
- Replace hardcoded `CLICKHOUSE_ENDPOINT`/`CLICKHOUSE_USER`/`<password>` with `secretKeyRef` into `clickhouse-credentials`.
- Confirm/pin the ClickStack collector image tag.
- Keep `ports.otlp` + `ports.otlp-http` enabled (agent + demo ingress).

**`k8s-daemonset-values.yaml`**
- Fix `extraEnvs` placeholder bug: `<YOUR_OTEL_COLLECTOR_ENDPOINT>` (angle brackets, both name and key) → `YOUR_OTEL_COLLECTOR_ENDPOINT`. The angle-bracket form never resolves the env var, breaking the exporter endpoint.

**`k8s-deployment-values.yaml`**
- Already references `otel-config-vars` / `YOUR_OTEL_COLLECTOR_ENDPOINT` correctly; verify only.

**Service name alignment / Helm release names**
- The gateway service name is `<release>-opentelemetry-collector`. The gateway Helm release name is **`clickstack-gateway`** (load-bearing — the agents' and demo's `OTEL_GATEWAY_ENDPOINT` = `clickstack-gateway-opentelemetry-collector:4318` must match it).
- Other release names are identifiers only (not referenced elsewhere): DaemonSet agent `otel-agent`, Deployment agent `otel-cluster`, OTel Demo `otel-demo`.

## Gateway Deployment — Option A (with gate + fallback)

Deploy the ClickStack collector image via the upstream `opentelemetry-collector` chart,
relying on the image's baked-in ClickHouse pipeline + `CLICKHOUSE_*` env vars.

**Known risk:** the upstream chart always renders its own config and passes `--config`,
which can override the image's baked-in ClickHouse pipeline.

**Verification gate:** after deploy, confirm the gateway log shows the `clickhouse`
exporter initializing and a successful connection (no auth/TLS errors), and that data
reaches Cloud.

**Fallback if overridden:** either (a) provide the ClickHouse exporter pipeline explicitly
in `gateway-values.yaml`'s `config:` block (env-substituted `CLICKHOUSE_*`), or (b) move the
gateway release to the dedicated `ClickHouse/ClickStack-helm-charts` chart. Agents/demo are unaffected.

## OpenTelemetry Demo Integration

- Install via `open-telemetry/opentelemetry-demo` Helm chart into `otel-demo`.
- Point the demo's **bundled collector** at our gateway by adding an `otlphttp` exporter
  (endpoint = `OTEL_GATEWAY_ENDPOINT`) to its traces/metrics/logs pipelines, preserving the
  existing `spanmetrics` exporter on the traces pipeline (Helm merges objects, replaces arrays).
- Disable the demo's bundled Jaeger / Prometheus / Grafana / OpenSearch to keep the footprint light
  (our gateway + ClickHouse Cloud are the backend).

## Deploy UX (hybrid)

**Scripts + Makefile:**
- `scripts/deploy-otel.sh`: `helm repo add` (open-telemetry, clickstack) + `helm repo update`;
  create `observability` + `otel-demo` namespaces; create Secret + ConfigMap from `.env`;
  install in order **gateway → agents → demo**; wait for rollout.
- `scripts/teardown-otel.sh`: uninstall releases, delete Secret/ConfigMap, optionally delete namespaces.
- Makefile targets: `otel-up`, `otel-down`, `otel-status`.

**README:** the equivalent raw `helm`/`kubectl` commands, with a note that either the
scripted path or the raw commands work.

## Verification (end-to-end)

1. **Gateway → Cloud:** `kubectl logs` on the gateway shows the `clickhouse` exporter loaded and connected (no auth/TLS errors).
2. **Agents:** DaemonSet pod Running on every node; Deployment agent (1 replica) Running.
3. **Demo:** demo pods Running; bundled collector Running.
4. **HyperDX UI (Cloud):**
   - Logs: cluster + demo pod logs searchable.
   - Metrics: `kubeletstats` (pod/node CPU/mem) and cluster metrics present.
   - Traces: demo traces with a populated service map / span waterfall.
5. **SQL sanity:** query ClickHouse Cloud (`SELECT count() ...`) confirming the `otel_*`
   tables (logs/metrics/traces) are filling.

## Out of Scope
- Production-grade tuning (batching/retry/memory limits beyond defaults, autoscaling, persistence).
- Sampling strategies, multi-cluster/region gateways.
- Custom ClickHouse schema/TTL beyond ClickStack defaults.
- Alerting/dashboards beyond what HyperDX provides out of the box.
