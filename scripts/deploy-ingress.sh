#!/usr/bin/env bash
# Deploy ingress-nginx and an Ingress that exposes the OTel Demo UI on
# http://localhost:8080. Idempotent: safe to re-run.
#
# Mechanism: kind already publishes host 8080 -> control-plane node :80 (see
# kind/cluster-config.yaml extraPortMappings). ingress-nginx binds hostPort 80
# on that node, so we pin the controller to the control-plane node. An Ingress
# then routes / to the demo's frontend-proxy service.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned ingress-nginx release. k8s here (v1.36.1) is newer than any release
# officially tests against, so we verify the controller reaches Ready below;
# bump this tag if it fails to come up.
INGRESS_NGINX_VERSION="controller-v1.15.1"
MANIFEST_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a

scripts/preflight.sh   # ensures docker/kind/kubectl/helm/envsubst

CONTROL_PLANE="$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')"
[ -n "$CONTROL_PLANE" ] || { echo "ERROR: no control-plane node found. Is the cluster up? (make up)" >&2; exit 1; }

# The demo's frontend-proxy is the Ingress backend; fail fast if it's missing.
if ! kubectl -n otel-demo get svc frontend-proxy >/dev/null 2>&1; then
  echo "ERROR: service otel-demo/frontend-proxy not found." >&2
  echo "       Deploy the demo first: make otel-up" >&2
  exit 1
fi

echo "Installing ingress-nginx (${INGRESS_NGINX_VERSION})..."
kubectl apply -f "$MANIFEST_URL"

# The kind manifest only requires kubernetes.io/os=linux, so on a multi-node
# cluster the controller could land on a worker where hostPort 80 has no host
# mapping. Pin it to the control-plane node (the one with the 8080->:80 map);
# the manifest already tolerates the control-plane taint.
echo "Pinning controller to control-plane node ($CONTROL_PLANE)..."
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type merge -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux","node-role.kubernetes.io/control-plane":""}}}}}'

echo "Waiting for the ingress-nginx controller to become Ready..."
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
# Ensure the admission webhook is actually serving before we apply the Ingress.
kubectl -n ingress-nginx wait --for=condition=ready pod \
  -l app.kubernetes.io/component=controller --timeout=180s

echo "Applying the demo Ingress..."
kubectl apply -f ingress/frontend-ingress.yaml

echo "Verifying http://localhost:8080/ ..."
code=""
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://localhost:8080/ || true)"
  [ "$code" = "200" ] && break
  sleep 2
done
if [ "$code" = "200" ]; then
  echo
  echo "OTel Demo UI is live: http://localhost:8080"
else
  echo
  echo "WARNING: http://localhost:8080/ returned '$code' (expected 200)." >&2
  echo "Check: kubectl -n ingress-nginx get pods; kubectl -n otel-demo get ingress" >&2
  exit 1
fi
