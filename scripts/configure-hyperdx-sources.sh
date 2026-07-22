#!/usr/bin/env bash
# Configure the four HyperDX data sources — Logs, Traces, Metrics, Sessions — in your
# Managed/self-hosted ClickStack so the remote-demo walkthrough works against YOUR
# ClickHouse. This creates HyperDX SOURCES (app config that points HyperDX at tables);
# it does NOT create ClickHouse tables — the ClickStack collector already did that.
#
# IMPORTANT: HyperDX's source-CREATION API is not part of the published OpenAPI spec, so
# the create calls below are BEST-EFFORT and cannot be pre-verified here. The script
# always prints the exact settings for each source; if a create call fails (or you omit
# --apply), configure them by hand in Team Settings -> Sources using those values (the
# README "Replicate the walkthrough" section has the click-by-click steps — the reliable
# path). Reading/creating sources requires a HyperDX *Personal* API key.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
: "${CLICKHOUSE_ENDPOINT:?set in .env}"
: "${CLICKHOUSE_USER:?set in .env}"
: "${CLICKHOUSE_PASSWORD:?set in .env}"
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found ('brew install jq')." >&2; exit 1; }

DB="${CLICKHOUSE_DB:-default}"
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1

# --- The four sources: name | kind | table(s) ------------------------------------------
# (defaultTableSelectExpression / timestamp / trace-id columns follow the default OTel
# schema, which HyperDX infers automatically.)
print_settings() {
  cat <<EOF

Configure these in HyperDX -> Team Settings -> Sources (all use database '$DB'):

  Logs      kind=Log      table=otel_logs
              Timestamp=Timestamp  Trace Id=TraceId  Span Id=SpanId
              Correlated Trace Source = "Traces"   <-- enables the log's "Trace" button
  Traces    kind=Trace    table=otel_traces
              Timestamp=Timestamp  Trace Id=TraceId  Span Id=SpanId
  Metrics   kind=Metric   Gauge=otel_metrics_gauge  Sum=otel_metrics_sum  Histogram=otel_metrics_histogram
  Sessions  kind=Session  table=hyperdx_sessions
EOF
}

# --- Readiness: confirm the tables exist and have data (so sources will show something) --
CH_HOST="$(echo "$CLICKHOUSE_ENDPOINT" | sed -E 's#https?://##; s#[:/].*##')"
ch() { curl -sS "https://$CH_HOST:8443" --user "$CLICKHOUSE_USER:$CLICKHOUSE_PASSWORD" --data-binary "$1"; }
echo "=== ClickHouse readiness (database '$DB') ==="
for t in otel_logs otel_traces otel_metrics_gauge otel_metrics_sum otel_metrics_histogram hyperdx_sessions; do
  n="$(ch "SELECT count() FROM $DB.$t" 2>/dev/null || echo '?')"
  printf "  %-24s rows=%s\n" "$t" "$n"
done
echo "  (0 rows just means no traffic yet — deploy with SCENARIOS=paymentCacheLeak and drive checkouts.)"

# --- HyperDX API (best-effort) ----------------------------------------------------------
if [ -z "${HYPERDX_API_URL:-}" ] || [ -z "${HYPERDX_API_KEY:-}" ]; then
  echo
  echo "HYPERDX_API_URL / HYPERDX_API_KEY not set in .env — skipping API automation."
  print_settings
  exit 0
fi

API="${HYPERDX_API_URL%/}/api/v2"
hdx() { curl -sS -H "Authorization: Bearer $HYPERDX_API_KEY" -H "Content-Type: application/json" "$@"; }

echo
echo "=== Existing HyperDX sources (via $API/sources) ==="
if ! SOURCES_JSON="$(hdx "$API/sources")"; then
  echo "  ERROR: could not reach the HyperDX API. Configure sources via the UI instead." >&2
  print_settings; exit 1
fi
echo "$SOURCES_JSON" | jq -r '.[]? | "  - \(.name) (kind=\(.kind))"' 2>/dev/null || echo "  (none / unexpected response)"

# Reuse an existing ClickHouse connection, else create one.
CONN_ID="$(hdx "$API/connections" | jq -r --arg h "$CH_HOST" '.[]? | select(.host|test($h)) | .id' 2>/dev/null | head -1)"
if [ -z "$CONN_ID" ] && [ "$APPLY" = "1" ]; then
  CONN_ID="$(hdx -X POST "$API/connections" -d "$(jq -n --arg n "clickstack-k8s" --arg h "https://$CH_HOST:8443" \
      --arg u "$CLICKHOUSE_USER" --arg p "$CLICKHOUSE_PASSWORD" \
      '{name:$n, host:$h, username:$u, password:$p}')" | jq -r '.id // empty')"
fi

ensure_source() { # name kind extra-json
  local name="$1" kind="$2" extra="$3"
  if echo "$SOURCES_JSON" | jq -e --arg n "$name" '.[]?|select(.name==$n)' >/dev/null 2>&1; then
    echo "  source '$name' already exists — leaving as-is."; return
  fi
  if [ "$APPLY" != "1" ]; then echo "  source '$name' missing — rerun with --apply to attempt create, or use the UI."; return; fi
  [ -n "$CONN_ID" ] || { echo "  no ClickHouse connection id — create sources in the UI."; return; }
  local body; body="$(jq -n --arg n "$name" --arg k "$kind" --arg c "$CONN_ID" --arg db "$DB" --argjson x "$extra" \
     '{name:$n, kind:$k, connection:$c, from:{databaseName:$db}} * $x')"
  local resp; resp="$(hdx -X POST "$API/sources" -d "$body" || true)"
  if echo "$resp" | jq -e '.id' >/dev/null 2>&1; then echo "  created source '$name'."; else
    echo "  could NOT create '$name' via API (create it in the UI). Response: $(echo "$resp" | head -c 160)"; fi
}

echo
echo "=== Ensuring the four sources ==="
ensure_source "Logs"     "log"     '{from:{tableName:"otel_logs"},   timestampValueExpression:"Timestamp", traceIdExpression:"TraceId", spanIdExpression:"SpanId"}'
ensure_source "Traces"   "trace"   '{from:{tableName:"otel_traces"}, timestampValueExpression:"Timestamp", traceIdExpression:"TraceId", spanIdExpression:"SpanId"}'
ensure_source "Metrics"  "metric"  '{metricTables:{gauge:"otel_metrics_gauge", sum:"otel_metrics_sum", histogram:"otel_metrics_histogram"}}'
ensure_source "Sessions" "session" '{from:{tableName:"hyperdx_sessions"}, timestampValueExpression:"TimestampTime"}'

print_settings
echo
echo "Verify in HyperDX (Team Settings -> Sources), then set the Logs source's"
echo "'Correlated Trace Source' to 'Traces' so logs show a working Trace button."
