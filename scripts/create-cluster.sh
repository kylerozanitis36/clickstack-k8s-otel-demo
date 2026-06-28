#!/usr/bin/env bash
# Create (or no-op if it already exists) the local kind cluster from .env + the
# kind config template. Safe to re-run.
set -euo pipefail

# Always operate from the repo root (parent of this script's dir).
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }

# Load .env into the environment.
set -a; . ./.env; set +a
: "${CLUSTER_NAME:?CLUSTER_NAME must be set in .env}"
: "${KIND_NODE_IMAGE:?KIND_NODE_IMAGE must be set in .env}"

# Verify tooling / Docker.
scripts/preflight.sh

# envsubst (from gettext) is keg-only on macOS; fall back to its Homebrew path.
ENVSUBST="$(command -v envsubst || true)"
[ -n "$ENVSUBST" ] || ENVSUBST="$(brew --prefix gettext)/bin/envsubst"

# Render the kind config from the template.
RENDERED="kind/.cluster-config.rendered.yaml"
"$ENVSUBST" '${CLUSTER_NAME} ${KIND_NODE_IMAGE}' < kind/cluster-config.yaml > "$RENDERED"

# Idempotent create.
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster '$CLUSTER_NAME' already exists. Skipping create."
else
  echo "Creating kind cluster '$CLUSTER_NAME'..."
  kind create cluster --config "$RENDERED"
fi

echo "Waiting for all nodes to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo
kubectl get nodes -o wide
echo
echo "Cluster '$CLUSTER_NAME' is ready. kubeconfig: ${KUBECONFIG:-~/.kube/config}"
