#!/usr/bin/env bash
# Deploy the full OTel → ClickStack pipeline: gateway → agents → demo.
# Idempotent: safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
: "${CLICKHOUSE_ENDPOINT:?set in .env}"
: "${CLICKHOUSE_USER:?set in .env}"
: "${CLICKHOUSE_PASSWORD:?set in .env}"
: "${OTEL_GATEWAY_ENDPOINT:?set in .env}"
: "${CLICKHOUSE_DEMO_FORK_REF:?set in .env}"

scripts/preflight.sh   # docker/kind/kubectl/helm/compose/kustomize/envsubst/jq/git

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

# --- OTel Demo (ClickHouse fork manifest) ------------------------------------
# The demo is no longer a Helm chart: we apply the fork's own manifest, vendored
# verbatim under otel-demo/upstream/ and customised by otel-demo/kustomization.yaml.
# Its images are built locally for this architecture by scripts/build-demo-images.sh,
# because the fork publishes amd64 only.

# A manifest from one commit with images from another is the most likely way this
# breaks subtly, so all three sources of the fork version must agree.
MANIFEST_SHA="$(awk '/^commit:/{print $2}' otel-demo/upstream/SOURCE)"
IMAGES_SHA="$(cat .cache/demo-images.sha 2>/dev/null || true)"

if [ "$MANIFEST_SHA" != "$CLICKHOUSE_DEMO_FORK_REF" ]; then
  echo "ERROR: vendored manifest is from ${MANIFEST_SHA:0:12} but CLICKHOUSE_DEMO_FORK_REF" >&2
  echo "       is ${CLICKHOUSE_DEMO_FORK_REF:0:12}. Run: scripts/refresh-demo-manifest.sh" >&2
  exit 1
fi
if [ -z "$IMAGES_SHA" ]; then
  echo "ERROR: demo images have not been built. Run: make demo-images" >&2
  exit 1
fi
if [ "$IMAGES_SHA" != "$CLICKHOUSE_DEMO_FORK_REF" ]; then
  echo "ERROR: demo images were built from ${IMAGES_SHA:0:12} but CLICKHOUSE_DEMO_FORK_REF" >&2
  echo "       is ${CLICKHOUSE_DEMO_FORK_REF:0:12}. Run: make demo-images" >&2
  exit 1
fi

# The demo used to be a Helm release. Helm and kubectl fight over ownership of the
# same object names, so refuse to apply on top of one rather than half-converting.
if helm status otel-demo -n otel-demo >/dev/null 2>&1; then
  echo "ERROR: an old Helm release 'otel-demo' is still installed. Remove it first:" >&2
  echo "         make otel-down" >&2
  exit 1
fi

scripts/check-overlay.sh
kubectl apply -k otel-demo/

echo
echo "OTel pipeline deployed. Check status with: make otel-status"
echo "Failure scenarios are the fork's flagd defaults (paymentCacheLeak on)."
echo "Toggle them in the flagd-ui: kubectl -n otel-demo port-forward deploy/flagd 4000:4000"
