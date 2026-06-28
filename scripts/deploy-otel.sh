#!/usr/bin/env bash
# Deploy the full OTel → ClickStack pipeline: gateway → agents → demo.
# Idempotent: safe to re-run (uses `helm upgrade --install` and applies).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
: "${CLICKHOUSE_ENDPOINT:?set in .env}"
: "${CLICKHOUSE_USER:?set in .env}"
: "${CLICKHOUSE_PASSWORD:?set in .env}"
: "${OTEL_GATEWAY_ENDPOINT:?set in .env}"

scripts/preflight.sh   # ensures docker/kind/kubectl/helm/envsubst

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null

# Namespaces
for ns in observability otel-demo; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# Credentials Secret + gateway-endpoint ConfigMap (idempotent)
kubectl create secret generic clickhouse-credentials -n observability \
  --from-literal=CLICKHOUSE_ENDPOINT="$CLICKHOUSE_ENDPOINT" \
  --from-literal=CLICKHOUSE_USER="$CLICKHOUSE_USER" \
  --from-literal=CLICKHOUSE_PASSWORD="$CLICKHOUSE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap otel-config-vars -n observability \
  --from-literal=YOUR_OTEL_COLLECTOR_ENDPOINT="$OTEL_GATEWAY_ENDPOINT" \
  --dry-run=client -o yaml | kubectl apply -f -

# Gateway (only component that exports to ClickHouse Cloud)
helm upgrade --install clickstack-gateway open-telemetry/opentelemetry-collector \
  -n observability -f otel/gateway-values.yaml
kubectl -n observability rollout status deploy/clickstack-gateway-opentelemetry-collector --timeout=120s

# Agents → gateway
helm upgrade --install otel-agent   open-telemetry/opentelemetry-collector -n observability -f otel/k8s-daemonset-values.yaml
helm upgrade --install otel-cluster open-telemetry/opentelemetry-collector -n observability -f otel/k8s-deployment-values.yaml

# OTel Demo (render the gateway endpoint into the values via envsubst)
ENVSUBST="$(command -v envsubst || echo "$(brew --prefix gettext)/bin/envsubst")"
"$ENVSUBST" '${OTEL_GATEWAY_ENDPOINT}' < otel/otel-demo-values.yaml > otel/.otel-demo-values.rendered.yaml
helm upgrade --install otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo -f otel/.otel-demo-values.rendered.yaml

echo
echo "OTel pipeline deployed. Check status with: make otel-status"
