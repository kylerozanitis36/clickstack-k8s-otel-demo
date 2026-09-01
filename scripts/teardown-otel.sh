#!/usr/bin/env bash
# Tear down the OTel pipeline (keeps the kind cluster itself).
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl delete -k otel-demo/ --ignore-not-found 2>/dev/null || true
helm uninstall otel-demo -n otel-demo 2>/dev/null || true   # legacy chart installs
helm uninstall otel-agent   -n observability  2>/dev/null || true
helm uninstall otel-cluster -n observability  2>/dev/null || true
helm uninstall clickstack-gateway -n observability 2>/dev/null || true

kubectl -n observability delete secret clickhouse-credentials --ignore-not-found
kubectl -n observability delete configmap otel-config-vars --ignore-not-found
kubectl delete namespace otel-demo --ignore-not-found
kubectl delete namespace observability --ignore-not-found

echo "OTel pipeline removed."
