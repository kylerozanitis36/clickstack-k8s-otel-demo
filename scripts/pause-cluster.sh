#!/usr/bin/env bash
# Pause the local kind cluster by STOPPING its node containers. This is not a teardown:
# nothing is deleted, all cluster + workload state is preserved on the container disks.
# Frees CPU/RAM while paused. Resume with `make resume`.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
: "${CLUSTER_NAME:?CLUSTER_NAME must be set in .env}"

docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running." >&2; exit 1; }

# kind runs each node as a Docker container labelled with the cluster name.
FILTER="label=io.x-k8s.kind.cluster=$CLUSTER_NAME"
RUNNING="$(docker ps -q --filter "$FILTER")"

if [ -z "$RUNNING" ]; then
  if [ -z "$(docker ps -aq --filter "$FILTER")" ]; then
    echo "No kind cluster '$CLUSTER_NAME' found. Nothing to pause (run 'make up' to create it)."
  else
    echo "Cluster '$CLUSTER_NAME' is already paused."
  fi
  exit 0
fi

echo "Pausing kind cluster '$CLUSTER_NAME' (stopping node containers; state preserved)..."
docker stop $RUNNING >/dev/null

echo
docker ps -a --filter "$FILTER" --format '  {{.Names}}\t{{.Status}}'
echo
echo "Paused. Resume with: make resume"
