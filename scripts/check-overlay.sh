#!/usr/bin/env bash
# Assert the kustomize overlay still does what we think it does.
#
# This is the closest thing this repo has to a unit test: it renders the overlay
# and checks the invariants that keep the demo runnable on arm64. It is cheap, so
# deploy-otel.sh runs it on every deploy — a fork refresh that silently drops one
# of these is caught here rather than as a crash-looping pod.
set -euo pipefail
cd "$(dirname "$0")/.."

RENDERED="$(kubectl kustomize otel-demo/)"

fail() { echo "OVERLAY CHECK FAILED: $*" >&2; exit 1; }

# 1. Every demo image points at our locally built copy, never the amd64-only upstream.
if grep -q 'image: clickhouse/ch-otel-demo' <<<"$RENDERED"; then
  fail "some images still reference clickhouse/ch-otel-demo (amd64-only)"
fi
count="$(grep -c 'image: clickstack-local/ch-otel-demo:' <<<"$RENDERED" || true)"
[ "$count" -eq 19 ] || fail "expected 19 local demo images, found $count"

# 2. Nothing may re-pull over a kind-loaded image.
if grep -q 'imagePullPolicy: Always' <<<"$RENDERED"; then
  fail "imagePullPolicy: Always survives somewhere; kind-loaded arm64 images would be replaced"
fi

# 3. The Visa cache must be small enough to actually fill.
grep -q 'value: "10"' <<<"$(grep -A1 'name: CACHE_SIZE' <<<"$RENDERED")" \
  || fail "payment CACHE_SIZE is not 10"

# 4. Unused workloads stay deleted.
# NB: written as if/then, not "grep && fail" — under `set -e` a failing grep in an
# && chain exits the script, which would turn the success case into a failure.
if grep -q 'name: jaeger' <<<"$RENDERED"; then
  fail "jaeger was not removed"
fi

# 5. Our two additions are present.
grep -q 'name: my-clickstack-otel-collector' <<<"$RENDERED" \
  || fail "gateway alias Service missing"
grep -q 'name: hyperdx-secret' <<<"$RENDERED" || fail "hyperdx-secret missing"

echo "Overlay check OK: 19 local images, no Always pulls, CACHE_SIZE=10, jaeger removed, alias + secret present."
