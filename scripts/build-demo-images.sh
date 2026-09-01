#!/usr/bin/env bash
# Build the ClickHouse OTel-demo fork's service images for THIS host's
# architecture and load them into the kind cluster.
#
# Why we build at all: the fork publishes amd64-only images, so on Apple Silicon
# they cannot run. Compose builds all 19 services from source, which is also the
# only way we receive the fork's instrumentation in every service rather than a
# hand-picked few.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "ERROR: .env not found. Run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a

REPO="${CLICKHOUSE_DEMO_FORK_REPO:-https://github.com/ClickHouse/opentelemetry-demo.git}"
REF="${CLICKHOUSE_DEMO_FORK_REF:?set CLICKHOUSE_DEMO_FORK_REF in .env}"
CLUSTER="${CLUSTER_NAME:-clickstack-local}"
LOCAL_IMAGE_NAME="clickstack-local/ch-otel-demo"
SRC=".cache/otel-demo-fork"

scripts/preflight.sh

SERVICES="accounting ad artillery-loadgen cart checkout currency email flagd-ui \
fraud-detection frontend frontend-proxy image-provider kafka load-generator payment \
product-catalog quote recommendation shipping"

# --- Fetch the fork at the pinned commit ------------------------------------
echo "Cloning fork @ ${REF:0:12}..."
rm -rf "$SRC"; mkdir -p "$SRC"
git -C "$SRC" init -q
git -C "$SRC" remote add origin "$REPO"
git -C "$SRC" fetch -q --depth 1 origin "$REF"
git -C "$SRC" checkout -q FETCH_HEAD

# --- Patch 1: accounting's NuGet audit gate ---------------------------------
# Directory.Build.props sets NuGetAudit at level "low" AND TreatWarningsAsErrors
# for Release builds, so any advisory published after this pinned commit turns
# into an NU1902 build error. Pinning for reproducibility and failing on new
# advisories are mutually exclusive; for a local demo build we keep the pin.
# (Reported upstream — the real fix is bumping the OpenTelemetry packages.)
PROPS="$SRC/src/accounting/Directory.Build.props"
grep -q '<TreatWarningsAsErrors>true</TreatWarningsAsErrors>' "$PROPS" \
  || { echo "ERROR: accounting patch no longer applies — inspect $PROPS" >&2; exit 1; }
sed -i.bak 's#<TreatWarningsAsErrors>true</TreatWarningsAsErrors>##' "$PROPS"
rm -f "$PROPS.bak"

# --- Patch 2: swap in our multi-arch artillery image ------------------------
# The fork builds FROM artilleryio/artillery, which is amd64-only on every tag.
ART="$SRC/src/artillery-load-generator"
grep -q '^FROM artilleryio/artillery' "$ART/Dockerfile" \
  || { echo "ERROR: artillery patch no longer applies — inspect $ART/Dockerfile" >&2; exit 1; }
cp otel-demo/artillery/Dockerfile otel-demo/artillery/run.sh "$ART/"

# --- Build ------------------------------------------------------------------
HOST_ARCH="$(docker version --format '{{.Server.Arch}}')"
echo "Building 19 services for linux/${HOST_ARCH} (first run takes ~12 minutes)..."
FAILED=""
for s in $SERVICES; do
  printf '  %-20s ' "$s"
  if (cd "$SRC" && IMAGE_NAME="$LOCAL_IMAGE_NAME" docker compose build "$s") \
       > ".cache/build-$s.log" 2>&1; then
    echo "ok"
  else
    echo "FAILED (see .cache/build-$s.log)"
    FAILED="$FAILED $s"
  fi
done
[ -z "$FAILED" ] || { echo "ERROR: build failed for:$FAILED" >&2; exit 1; }

# --- Assert architecture ----------------------------------------------------
# A build can succeed and still produce the wrong architecture if a base image
# is single-arch — that is exactly how the artillery image slipped through
# during design. Check rather than assume.
TAGS=""
for s in $SERVICES; do
  tag="$LOCAL_IMAGE_NAME:latest-$s"
  # compose names the artillery service's image "latest-artillery"
  [ "$s" = "artillery-loadgen" ] && tag="$LOCAL_IMAGE_NAME:latest-artillery"
  got="$(docker image inspect "$tag" --format '{{.Architecture}}')"
  [ "$got" = "$HOST_ARCH" ] \
    || { echo "ERROR: $tag is $got, expected $HOST_ARCH" >&2; exit 1; }
  TAGS="$TAGS $tag"
done
echo "All 19 images verified linux/${HOST_ARCH}."

# --- Load into kind ---------------------------------------------------------
echo "Loading images into kind cluster '$CLUSTER'..."
# shellcheck disable=SC2086
kind load docker-image $TAGS --name "$CLUSTER"

echo "$REF" > .cache/demo-images.sha
echo "Done. Images built from ${REF:0:12} and loaded. Next: make otel-up"
