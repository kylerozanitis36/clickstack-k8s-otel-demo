#!/usr/bin/env bash
# Configure the four HyperDX data sources — Logs, Traces, Metrics, Sessions — in your
# **Managed ClickStack on ClickHouse Cloud** so the remote-demo walkthrough works against
# YOUR ClickHouse. This creates HyperDX SOURCES (app config pointing HyperDX at tables +
# correlating them); it does NOT create ClickHouse tables — the ClickStack collector already
# did that.
#
# Managed ClickStack is driven through the ClickHouse Cloud API:
#   https://api.clickhouse.cloud/v1/organizations/<ORG_ID>/services/<SERVICE_ID>/clickstack/<resource>
# authenticated with a ClickHouse Cloud API key via HTTP Basic auth. (This is different from
# self-hosted HyperDX, which uses a Bearer Personal API key at <host>:8000/api/v2.)
#
# IMPORTANT: the ClickStack source/connection CREATE endpoints are **Beta** in the Cloud API
# (and the exact metric-tables schema isn't fully published), so the create calls here are
# BEST-EFFORT and can't be pre-verified. The script always prints the exact settings; if a
# create call fails (or you omit --apply), configure the sources by hand in the hosted
# HyperDX UI -> Team Settings -> Sources (the README table is the reliable path).
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

print_settings() {
  cat <<EOF

Configure these in the hosted HyperDX UI -> Team Settings -> Sources (all use database '$DB'):

  Logs      kind=Log      table=otel_logs
              Timestamp=Timestamp  Trace Id=TraceId  Span Id=SpanId
              Correlated Trace Source = "Traces"   <-- enables the log's "Trace" button
  Traces    kind=Trace    table=otel_traces
              Timestamp=Timestamp  Trace Id=TraceId  Span Id=SpanId
  Metrics   kind=Metric   Gauge=otel_metrics_gauge  Sum=otel_metrics_sum  Histogram=otel_metrics_histogram
  Sessions  kind=Session  table=hyperdx_sessions
EOF
}

# --- Readiness: confirm the tables exist and have data (so sources will show something) ---
CH_HOST="$(echo "$CLICKHOUSE_ENDPOINT" | sed -E 's#https?://##; s#[:/].*##')"
ch() { curl -sS "https://$CH_HOST:8443" --user "$CLICKHOUSE_USER:$CLICKHOUSE_PASSWORD" --data-binary "$1"; }
echo "=== ClickHouse readiness (database '$DB') ==="
for t in otel_logs otel_traces otel_metrics_gauge otel_metrics_sum otel_metrics_histogram hyperdx_sessions; do
  printf "  %-24s rows=%s\n" "$t" "$(ch "SELECT count() FROM $DB.$t" 2>/dev/null || echo '?')"
done
echo "  (0 rows just means no traffic yet — deploy with SCENARIOS=paymentCacheLeak and drive checkouts.)"

# --- Managed Cloud API (best-effort) ----------------------------------------------------
if [ -z "${CLICKHOUSE_CLOUD_ORG_ID:-}" ] || [ -z "${CLICKHOUSE_CLOUD_SERVICE_ID:-}" ] \
   || [ -z "${CLICKHOUSE_CLOUD_API_KEY_ID:-}" ] || [ -z "${CLICKHOUSE_CLOUD_API_KEY_SECRET:-}" ]; then
  echo
  echo "Cloud API vars not set in .env (CLICKHOUSE_CLOUD_ORG_ID / _SERVICE_ID /"
  echo "_API_KEY_ID / _API_KEY_SECRET) — skipping API automation."
  print_settings
  exit 0
fi

API="https://api.clickhouse.cloud/v1/organizations/${CLICKHOUSE_CLOUD_ORG_ID}/services/${CLICKHOUSE_CLOUD_SERVICE_ID}/clickstack"
cc() { curl -sS --user "${CLICKHOUSE_CLOUD_API_KEY_ID}:${CLICKHOUSE_CLOUD_API_KEY_SECRET}" -H "Content-Type: application/json" "$@"; }

echo
echo "=== Existing ClickStack sources ($API/sources) ==="
if ! SOURCES_JSON="$(cc "$API/sources")" || ! echo "$SOURCES_JSON" | jq . >/dev/null 2>&1; then
  echo "  ERROR: could not read $API/sources (check org/service IDs, the Cloud API key, and that" >&2
  echo "  the key has the 'Manage ClickStack API' permission). Configure sources in the UI." >&2
  echo "  Response: $(echo "${SOURCES_JSON:-}" | head -c 200)" >&2
  print_settings; exit 1
fi
echo "$SOURCES_JSON" | jq -r '(.result // .)[]? | "  - \(.name) (kind=\(.kind))"' 2>/dev/null || echo "  (none)"

src_id()  { echo "$SOURCES_JSON" | jq -r --arg n "$1" '(.result // .)[]? | select(.name==$n) | .id' 2>/dev/null | head -1; }
has_src() { [ -n "$(src_id "$1")" ]; }

# Reuse an existing ClickHouse connection, else (with --apply) create one.
CONNS_JSON="$(cc "$API/connections" 2>/dev/null || echo '{}')"
CONN_ID="$(echo "$CONNS_JSON" | jq -r --arg h "$CH_HOST" '(.result // .)[]? | select((.host//"")|test($h)) | .id' 2>/dev/null | head -1)"
if [ -z "$CONN_ID" ] && [ "$APPLY" = "1" ]; then
  CONN_ID="$(cc -X POST "$API/connections" -d "$(jq -n --arg n "clickstack-k8s" --arg h "https://$CH_HOST:8443" \
      --arg u "$CLICKHOUSE_USER" --arg p "$CLICKHOUSE_PASSWORD" '{name:$n,host:$h,username:$u,password:$p}')" \
      | jq -r '.result.id // .id // empty' 2>/dev/null)"
  [ -n "$CONN_ID" ] && echo "  created ClickHouse connection ($CONN_ID)"
fi

# create_source <name> <extra-json>  (kind/from/expressions live in extra-json); echoes new id
create_source() {
  local name="$1" extra="$2"
  if has_src "$name"; then echo "  source '$name' already exists ($(src_id "$name"))"; src_id "$name"; return; fi
  if [ "$APPLY" != "1" ]; then echo "  source '$name' missing — rerun with --apply (or use the UI)"; return; fi
  [ -n "$CONN_ID" ] || { echo "  no connection id — create sources in the UI"; return; }
  local body resp id
  body="$(jq -n --arg n "$name" --arg c "$CONN_ID" --argjson x "$extra" '{name:$n, connection:$c} * $x')"
  resp="$(cc -X POST "$API/sources" -d "$body" || true)"
  id="$(echo "$resp" | jq -r '.result.id // .id // empty' 2>/dev/null)"
  if [ -n "$id" ]; then echo "  created source '$name' ($id)"; echo "$id"; else
    echo "  could NOT create '$name' via API (Beta endpoint / schema) — use the UI. Resp: $(echo "$resp" | head -c 200)" >&2; fi
}

echo
echo "=== Ensuring the four sources (Beta create API; best-effort) ==="
# Create Traces first so the Logs source can reference it for the log->trace correlation.
TRACE_ID="$(create_source "Traces"  '{kind:"trace", from:{databaseName:"'"$DB"'", tableName:"otel_traces"}, timestampValueExpression:"Timestamp", traceIdExpression:"TraceId", spanIdExpression:"SpanId"}' | tail -1)"
create_source "Metrics"  '{kind:"metric", from:{databaseName:"'"$DB"'"}, metricTables:{gauge:"otel_metrics_gauge", sum:"otel_metrics_sum", histogram:"otel_metrics_histogram"}}' >/dev/null
create_source "Sessions" '{kind:"session", from:{databaseName:"'"$DB"'", tableName:"hyperdx_sessions"}, timestampValueExpression:"TimestampTime"}' >/dev/null
LOG_EXTRA='{kind:"log", from:{databaseName:"'"$DB"'", tableName:"otel_logs"}, timestampValueExpression:"Timestamp", traceIdExpression:"TraceId", spanIdExpression:"SpanId"}'
if [ -n "${TRACE_ID:-}" ] && echo "$TRACE_ID" | grep -qvE 'source|missing|could'; then
  LOG_EXTRA="$(jq -c --arg t "$TRACE_ID" '. + {traceSourceId:$t}' <<<"$LOG_EXTRA")"  # log->trace correlation
fi
create_source "Logs" "$LOG_EXTRA" >/dev/null

print_settings
echo
echo "Verify in the hosted HyperDX UI (Team Settings -> Sources). If the Beta create API"
echo "didn't take, set them there by hand — including the Logs source's 'Correlated Trace"
echo "Source' = 'Traces' so logs show a working Trace button."
