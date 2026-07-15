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

# --- Resolve + validate failure scenarios (fail fast, before any deploy) ------
# The demo chart bakes its feature-flag catalog into a static file
# (flagd/demo.flagd.json) rendered into the chart-managed flagd-config ConfigMap;
# there is NO Helm value to override it, and overwriting that ConfigMap in place
# conflicts with Helm's server-side apply on the next upgrade. So we pull the chart,
# delta-patch the selected flags' defaultVariant, and later write the result into our
# OWN ConfigMap (flagd-config-scenarios) that flagd mounts via a values override, then
# restart flagd (which reads the file only at startup, via an init-container copy).
#
# SCENARIOS controls which failure patterns are enabled (see: make otel-scenarios):
#   unset / empty         -> the 3 defaults below
#   none                  -> no failure scenarios (clean/healthy demo)
#   "flag[=variant] ..."  -> exactly those flags (bare flag -> 'on',
#                            paymentFailure bare -> 25%)
DEFAULT_SCENARIOS="paymentFailure=25% recommendationCacheFailure=on productCatalogFailure=on"

CHART_DIR="$(mktemp -d)"
trap 'rm -rf "$CHART_DIR"' EXIT
helm pull open-telemetry/opentelemetry-demo --untar --untardir "$CHART_DIR" >/dev/null
DEMO_CHART="$CHART_DIR/opentelemetry-demo"
FLAG_SRC="$DEMO_CHART/flagd/demo.flagd.json"

variants_of() { jq -r --arg f "$1" '.flags[$f].variants | keys | join(", ")' "$FLAG_SRC"; }

SCENARIOS="${SCENARIOS:-}"
if [ -z "$SCENARIOS" ]; then
  SELECTION="$DEFAULT_SCENARIOS"
  echo "Failure scenarios: default ($DEFAULT_SCENARIOS)"
elif [ "$SCENARIOS" = "none" ]; then
  SELECTION=""
  echo "Failure scenarios: none (healthy demo)"
else
  SELECTION="$SCENARIOS"
  echo "Failure scenarios: custom ($SELECTION)"
fi

# Resolve + validate the selection into a JSON map {flag: variant, ...}.
SEL_JSON="{}"
for tok in $SELECTION; do
  if [ "$tok" = "none" ]; then
    echo "ERROR: 'none' cannot be combined with other scenarios." >&2; exit 1
  fi
  flag="${tok%%=*}"
  if [ "$tok" = "$flag" ]; then variant=""; else variant="${tok#*=}"; fi

  if ! jq -e --arg f "$flag" '.flags | has($f)' "$FLAG_SRC" >/dev/null; then
    echo "ERROR: unknown scenario flag '$flag'." >&2
    echo "  available: $(jq -r '.flags | keys | join(", ")' "$FLAG_SRC")" >&2
    echo "  (run 'make otel-scenarios' for descriptions)" >&2
    exit 1
  fi

  if [ -z "$variant" ]; then
    if jq -e --arg f "$flag" '.flags[$f].variants | has("on")' "$FLAG_SRC" >/dev/null; then
      variant="on"
    elif [ "$flag" = "paymentFailure" ]; then
      variant="25%"
    else
      echo "ERROR: flag '$flag' has no 'on' variant; specify one: ${flag}=<variant>" >&2
      echo "  valid variants: $(variants_of "$flag")" >&2
      exit 1
    fi
  fi

  if ! jq -e --arg f "$flag" --arg v "$variant" '.flags[$f].variants | has($v)' "$FLAG_SRC" >/dev/null; then
    echo "ERROR: '$variant' is not a valid variant for '$flag'." >&2
    echo "  valid variants: $(variants_of "$flag")" >&2
    exit 1
  fi

  SEL_JSON="$(jq --arg f "$flag" --arg v "$variant" '. + {($f): $v}' <<<"$SEL_JSON")"
done

# Produce the patched flag file: set defaultVariant for each selected flag.
PATCHED="$CHART_DIR/demo.flagd.patched.json"
jq --argjson sel "$SEL_JSON" '
  reduce ($sel | to_entries[]) as $e (.; .flags[$e.key].defaultVariant = $e.value)
' "$FLAG_SRC" > "$PATCHED"

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

# Our delta-patched flag ConfigMap. flagd mounts THIS (via the additionalVolumes
# override in otel-demo-values.yaml), not the chart's static flagd-config — so we
# never fight Helm for ownership of a chart-managed object. It must exist before the
# demo install so flagd can mount it on first start. We own it outright, so a plain
# client-side apply is clean and idempotent.
kubectl create configmap flagd-config-scenarios -n otel-demo \
  --from-file=demo.flagd.json="$PATCHED" \
  --dry-run=client -o yaml | kubectl apply -f -

# OTel Demo (render the gateway endpoint into the values via envsubst)
ENVSUBST="$(command -v envsubst || echo "$(brew --prefix gettext)/bin/envsubst")"
"$ENVSUBST" '${OTEL_GATEWAY_ENDPOINT}' < otel/otel-demo-values.yaml > otel/.otel-demo-values.rendered.yaml

# Install the demo from the pulled chart (the exact version we patched against above).
helm upgrade --install otel-demo "$DEMO_CHART" \
  -n otel-demo -f otel/.otel-demo-values.rendered.yaml

# flagd reads the flag file only at startup (an init container copies it), so when the
# ConfigMap content changes on a re-run, flagd needs a rollout to pick it up.
kubectl -n otel-demo rollout restart deploy/flagd
kubectl -n otel-demo rollout status deploy/flagd --timeout=120s

echo
if [ -n "$SELECTION" ]; then
  echo "Active failure scenarios: $(jq -r 'to_entries|map("\(.key)=\(.value)")|join(", ")' <<<"$SEL_JSON")"
else
  echo "Active failure scenarios: none (healthy demo)"
fi
echo "OTel pipeline deployed. Check status with: make otel-status"
