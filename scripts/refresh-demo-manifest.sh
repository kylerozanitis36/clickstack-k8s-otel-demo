#!/usr/bin/env bash
# Re-vendor the ClickHouse OTel-demo fork's Kubernetes manifest at a pinned commit.
#
# The vendored copy is VERBATIM. All of our customisation lives in
# otel-demo/kustomization.yaml, so that upgrading is: run this script with a new
# SHA, then read "git diff" to see exactly what the fork changed.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then set -a; . ./.env; set +a; fi
REPO="${CLICKHOUSE_DEMO_FORK_REPO:-https://github.com/ClickHouse/opentelemetry-demo.git}"
REF="${1:-${CLICKHOUSE_DEMO_FORK_REF:-}}"
if [ -z "$REF" ]; then
  echo "usage: $0 <fork-commit-sha>   (or set CLICKHOUSE_DEMO_FORK_REF in .env)" >&2
  exit 1
fi

DEST=otel-demo/upstream
mkdir -p "$DEST"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q
git -C "$TMP" remote add origin "$REPO"
git -C "$TMP" config core.sparseCheckout true
printf '%s\n' 'kubernetes/' > "$TMP/.git/info/sparse-checkout"
git -C "$TMP" fetch -q --depth 1 origin "$REF"
git -C "$TMP" checkout -q FETCH_HEAD
FULL_SHA="$(git -C "$TMP" rev-parse HEAD)"

cp "$TMP/kubernetes/opentelemetry-demo.yaml" "$DEST/opentelemetry-demo.yaml"

cat > "$DEST/SOURCE" <<EOF
repo: $REPO
commit: $FULL_SHA
path: kubernetes/opentelemetry-demo.yaml
vendored: $(date -u +%Y-%m-%dT%H:%M:%SZ)

This directory is a VERBATIM copy of the upstream fork. Never edit it by hand:
all customisation belongs in otel-demo/kustomization.yaml. To move to a newer
fork revision, run scripts/refresh-demo-manifest.sh <sha> and review the diff.
EOF

echo "Vendored kubernetes/opentelemetry-demo.yaml @ ${FULL_SHA:0:12} -> $DEST/"
