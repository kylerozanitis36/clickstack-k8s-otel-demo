#!/usr/bin/env bash
# Remove the demo Ingress and the ingress-nginx controller. Keeps the cluster
# and the OTel pipeline. Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."

INGRESS_NGINX_VERSION="controller-v1.15.1"
MANIFEST_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a

echo "Deleting the demo Ingress..."
kubectl delete -f ingress/frontend-ingress.yaml --ignore-not-found

echo "Deleting ingress-nginx (${INGRESS_NGINX_VERSION})..."
kubectl delete -f "$MANIFEST_URL" --ignore-not-found

echo
echo "Ingress removed. The cluster and OTel pipeline are untouched."
