#!/usr/bin/env bash
# Resume a kind cluster paused by `make pause`: start its node containers and wait for
# the API server + nodes to come back Ready. State is preserved; workloads self-heal
# (pods restart) once the nodes are up.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
: "${CLUSTER_NAME:?CLUSTER_NAME must be set in .env}"

docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running. Start Docker Desktop and retry." >&2; exit 1; }

FILTER="label=io.x-k8s.kind.cluster=$CLUSTER_NAME"
NODES="$(docker ps -aq --filter "$FILTER")"
[ -n "$NODES" ] || { echo "ERROR: no kind cluster '$CLUSTER_NAME' found. Run 'make up' to create it." >&2; exit 1; }

echo "Resuming kind cluster '$CLUSTER_NAME' (starting node containers)..."
docker start $NODES >/dev/null   # no-op for any already-running node

# The API server needs a moment after the control-plane container starts; poll until it
# answers, then wait for all nodes to report Ready.
echo "Waiting for the Kubernetes API to come back..."
for _ in $(seq 1 24); do          # up to ~2 min
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 5
done

echo "Waiting for all nodes to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s \
  || echo "WARNING: nodes not all Ready yet — give it a moment and check 'make status'." >&2

echo
kubectl get nodes -o wide
echo
echo "Cluster '$CLUSTER_NAME' resumed. Workload pods restart automatically; 'make status' to watch."
