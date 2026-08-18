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

# Fork build config for the Visa-cache scenario (optional in .env; defaults baked in).
# Used only when SCENARIOS selects paymentCacheLeak (see below).
CLICKHOUSE_DEMO_FORK_REPO="${CLICKHOUSE_DEMO_FORK_REPO:-https://github.com/ClickHouse/opentelemetry-demo.git}"
CLICKHOUSE_DEMO_FORK_REF="${CLICKHOUSE_DEMO_FORK_REF:-15969bb3fc531e6d88fb4071e3fc97f16d3e6834}"
VISA_CACHE_SIZE="${VISA_CACHE_SIZE:-10}"

# Pin the OTel Demo chart. Unpinned, `helm pull` floats to the newest chart, which silently
# breaks this repo's assumptions across major demo releases. Concretely, chart 0.41.0
# (appVersion 3.0.0):
#   - renamed the collector's `spanmetrics` connector to `span_metrics`, so our re-listed
#     traces exporter crash-loops the demo collector ("references exporter "spanmetrics"
#     which is not configured"), and
#   - replaced the Locust load generator with k6, so the ClickHouse-fork (Locust-based)
#     load-generator image runs but generates NO traffic — the paymentCacheLeak incident
#     never fires, and LOCUST_BROWSER_TRAFFIC_ENABLED becomes a no-op.
# 0.40.10 is the last chart with appVersion 2.2.0, which is what the fork images and the
# values/gotchas in CLAUDE.md are written against. Override via .env if you know why.
DEMO_CHART_VERSION="${DEMO_CHART_VERSION:-0.40.10}"

scripts/preflight.sh   # ensures docker/kind/kubectl/helm/envsubst/jq/git

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
# Default is payment-only: it mirrors the ClickStack payment incident walkthrough
# (checkout PlaceOrder failing on the payment charge) without the extra product-catalog
# / recommendation error noise. Add more via SCENARIOS="..." when a richer mix helps.
DEFAULT_SCENARIOS="paymentFailure=25%"

CHART_DIR="$(mktemp -d)"
trap 'rm -rf "$CHART_DIR"' EXIT
helm pull open-telemetry/opentelemetry-demo --version "$DEMO_CHART_VERSION" --untar --untardir "$CHART_DIR" >/dev/null
DEMO_CHART="$CHART_DIR/opentelemetry-demo"
FLAG_SRC="$DEMO_CHART/flagd/demo.flagd.json"

# Merge fork-only flags (e.g. paymentCacheLeak) that aren't in the stock chart catalog,
# so they're selectable/validatable like any other flag. A merged flag only DOES anything
# if the service reading it is also the fork build — deploy-otel.sh swaps in the fork
# payment + load-generator images when paymentCacheLeak is selected (see VISA_CACHE below).
if [ -f otel/flagd-extra-flags.json ]; then
  MERGED_FLAGS="$CHART_DIR/demo.flagd.merged.json"
  jq -s '.[0].flags += .[1].flags | .[0]' "$FLAG_SRC" otel/flagd-extra-flags.json > "$MERGED_FLAGS"
  FLAG_SRC="$MERGED_FLAGS"
fi

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

# The Visa-cache scenario needs the fork payment + load-generator images (built below),
# not just the flag — detect it from the resolved selection.
VISA_CACHE=0
if jq -e 'has("paymentCacheLeak")' <<<"$SEL_JSON" >/dev/null; then
  VISA_CACHE=1
fi

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
#
# Detect whether the selection changed vs what's already deployed. A fresh install
# needs no restarts (Helm starts flagd and its consumers together with the right
# flags); only a scenario CHANGE on a running cluster requires restarts (below).
FLAGS_CHANGED=0
if EXISTING_FLAGS=$(kubectl -n otel-demo get configmap flagd-config-scenarios \
      -o jsonpath='{.data.demo\.flagd\.json}' 2>/dev/null) && [ -n "$EXISTING_FLAGS" ]; then
  [ "$EXISTING_FLAGS" = "$(cat "$PATCHED")" ] || FLAGS_CHANGED=1
fi

kubectl create configmap flagd-config-scenarios -n otel-demo \
  --from-file=demo.flagd.json="$PATCHED" \
  --dry-run=client -o yaml | kubectl apply -f -

# OTel Demo (render the gateway endpoint into the values via envsubst)
ENVSUBST="$(command -v envsubst || echo "$(brew --prefix gettext)/bin/envsubst")"
"$ENVSUBST" '${OTEL_GATEWAY_ENDPOINT}' < otel/otel-demo-values.yaml > otel/.otel-demo-values.rendered.yaml

# Visa-cache scenario: swap three services to the fork build — the only ones that make the
# ClickStack walkthrough's incident appear. payment implements the visaValidationCache +
# paymentCacheLeak flag; the fork load-generator sends distinct Visa numbers that fill it;
# the fork frontend logs "Failed to place order" on checkout failure (the stock frontend has
# no such log). The fork's published images are amd64-only, so build them locally for THIS
# host arch and load into kind, then render the image-override overlay. Skipped entirely
# unless paymentCacheLeak was selected.
if [ "$VISA_CACHE" = "1" ]; then
  VISA_IMAGE_TAG="$CLICKHOUSE_DEMO_FORK_REF"
  VISA_PAYMENT_REPO="clickstack-visa-demo/payment"
  VISA_LOADGEN_REPO="clickstack-visa-demo/load-generator"
  VISA_FRONTEND_REPO="clickstack-visa-demo/frontend"
  pay_img="${VISA_PAYMENT_REPO}:${VISA_IMAGE_TAG}"
  lg_img="${VISA_LOADGEN_REPO}:${VISA_IMAGE_TAG}"
  fe_img="${VISA_FRONTEND_REPO}:${VISA_IMAGE_TAG}"

  if docker image inspect "$pay_img" "$lg_img" "$fe_img" >/dev/null 2>&1; then
    echo "ClickHouse-fork images already built for ref ${VISA_IMAGE_TAG:0:12}; skipping build."
  else
    echo "Building ClickHouse-fork payment + load-generator + frontend images ($(uname -m), ref ${VISA_IMAGE_TAG:0:12})..."
    FORK_DIR=".cache/clickhouse-otel-demo"
    rm -rf "$FORK_DIR"; mkdir -p "$FORK_DIR"
    git -C "$FORK_DIR" init -q
    git -C "$FORK_DIR" remote add origin "$CLICKHOUSE_DEMO_FORK_REPO"
    git -C "$FORK_DIR" config core.sparseCheckout true
    printf '%s\n' 'pb/' 'src/payment/' 'src/load-generator/' 'src/frontend/' > "$FORK_DIR/.git/info/sparse-checkout"
    git -C "$FORK_DIR" fetch -q --depth 1 origin "$CLICKHOUSE_DEMO_FORK_REF"
    git -C "$FORK_DIR" checkout -q FETCH_HEAD
    docker build -q -f "$FORK_DIR/src/payment/Dockerfile"        -t "$pay_img" "$FORK_DIR" >/dev/null
    docker build -q -f "$FORK_DIR/src/load-generator/Dockerfile" -t "$lg_img"  "$FORK_DIR" >/dev/null
    docker build -q -f "$FORK_DIR/src/frontend/Dockerfile"       -t "$fe_img"  "$FORK_DIR" >/dev/null
  fi
  echo "Loading fork images into kind cluster '${CLUSTER_NAME:-clickstack-local}'..."
  kind load docker-image "$pay_img" "$lg_img" "$fe_img" --name "${CLUSTER_NAME:-clickstack-local}" >/dev/null

  export VISA_PAYMENT_REPO VISA_LOADGEN_REPO VISA_FRONTEND_REPO VISA_IMAGE_TAG VISA_CACHE_SIZE
  "$ENVSUBST" '${VISA_PAYMENT_REPO} ${VISA_LOADGEN_REPO} ${VISA_FRONTEND_REPO} ${VISA_IMAGE_TAG} ${VISA_CACHE_SIZE}' \
    < otel/otel-demo-visa-cache-values.yaml > otel/.otel-demo-visa-cache-values.rendered.yaml
fi

# Install the demo from the pulled chart (the exact version we patched against above).
# Add the Visa-cache image-override overlay as a second -f only when that scenario is on.
if [ "$VISA_CACHE" = "1" ]; then
  helm upgrade --install otel-demo "$DEMO_CHART" -n otel-demo \
    -f otel/.otel-demo-values.rendered.yaml \
    -f otel/.otel-demo-visa-cache-values.rendered.yaml
else
  helm upgrade --install otel-demo "$DEMO_CHART" \
    -n otel-demo -f otel/.otel-demo-values.rendered.yaml
fi

# When the selection changed on an already-running cluster, restart flagd AND its
# consumers. flagd reads the flag file only at startup (init-container copy), so it
# needs a rollout to load the new file. Its consumers (product-catalog, recommendation,
# payment, cart, ...) hold their flagd connection and keep serving the PREVIOUS flags
# when only flagd restarts, so they must reconnect too — otherwise stale scenarios linger.
if [ "$FLAGS_CHANGED" = "1" ]; then
  kubectl -n otel-demo rollout restart deploy/flagd
  kubectl -n otel-demo rollout status deploy/flagd --timeout=120s
  CONSUMERS=$(kubectl -n otel-demo get deploy -o json \
    | jq -r '.items[] | select(any(.spec.template.spec.containers[].env[]?; .name=="FLAGD_HOST")) | .metadata.name' \
    | tr '\n' ' ')
  if [ -n "${CONSUMERS// /}" ]; then
    echo "Scenario selection changed — restarting flagd consumers so they pick it up:"
    echo "  $CONSUMERS"
    kubectl -n otel-demo rollout restart deploy $CONSUMERS
    kubectl -n otel-demo rollout status deploy/product-catalog --timeout=120s
  fi
fi

echo
if [ -n "$SELECTION" ]; then
  echo "Active failure scenarios: $(jq -r 'to_entries|map("\(.key)=\(.value)")|join(", ")' <<<"$SEL_JSON")"
else
  echo "Active failure scenarios: none (healthy demo)"
fi
echo "OTel pipeline deployed. Check status with: make otel-status"
