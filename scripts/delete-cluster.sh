#!/usr/bin/env bash
# Tear down the local kind cluster named in .env.
set -euo pipefail

cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
: "${CLUSTER_NAME:?CLUSTER_NAME must be set in .env}"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Deleting kind cluster '$CLUSTER_NAME'..."
  kind delete cluster --name "$CLUSTER_NAME"
else
  echo "Cluster '$CLUSTER_NAME' does not exist. Nothing to do."
fi

# Clean up the rendered config artifact.
rm -f kind/.cluster-config.rendered.yaml
