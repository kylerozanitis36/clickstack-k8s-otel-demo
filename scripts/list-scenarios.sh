#!/usr/bin/env bash
# List the OTel Demo failure-scenario feature flags and their variants, read straight
# from the demo chart's flag catalog. Use these names/variants with:
#   make otel-up SCENARIOS="flag[=variant] ..."
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm not found (run 'make otel-up' once, or 'brew install helm')." >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq not found ('brew install jq')." >&2; exit 1; }

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update open-telemetry >/dev/null

CHART_DIR="$(mktemp -d)"
trap 'rm -rf "$CHART_DIR"' EXIT
helm pull open-telemetry/opentelemetry-demo --untar --untardir "$CHART_DIR" >/dev/null
FLAG_SRC="$CHART_DIR/opentelemetry-demo/flagd/demo.flagd.json"
CHART_VER="$(grep '^version:' "$CHART_DIR/opentelemetry-demo/Chart.yaml" | awk '{print $2}')"

echo "Available failure-scenario flags (opentelemetry-demo chart $CHART_VER):"
echo
jq -r '
  .flags | to_entries[]
  | "  \(.key)\n      variants: \(.value.variants | keys | join(", "))\n      \(.value.description)\n"
' "$FLAG_SRC"

cat <<'EOF'
Usage:
  make otel-up                          # default: paymentFailure=25% recommendationCacheFailure=on productCatalogFailure=on
  make otel-up SCENARIOS=none           # healthy demo, no failures
  make otel-up SCENARIOS="paymentFailure=50% kafkaQueueProblems=on"

Notes:
  - A bare flag name resolves to its 'on' variant; paymentFailure bare -> 25%.
  - A flag without an 'on' variant must be given one explicitly (e.g. imageSlowLoad=5sec).
EOF
