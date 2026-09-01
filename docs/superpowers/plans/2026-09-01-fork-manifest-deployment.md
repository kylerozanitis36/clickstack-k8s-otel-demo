# Fork Manifest Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the OTel Demo from ClickHouse's fork manifest with locally built arm64 images, replacing the upstream Helm chart and the overlays that existed to work around it.

**Architecture:** The fork's `kubernetes/opentelemetry-demo.yaml` is vendored verbatim at a pinned commit under `otel-demo/upstream/` and customised by a kustomize overlay (kustomize ships inside kubectl). All 19 service images are built locally from the same commit via `docker compose build` and `kind load`ed. Demo telemetry reaches our existing gateway through an `ExternalName` Service alias, so the `observability` namespace, the ingress and `make hyperdx-sources` are untouched.

**Tech Stack:** bash, kubectl + built-in kustomize v5.8.1, kind, Docker Desktop (buildx), Helm (gateway/agents only), Make.

**Spec:** `docs/superpowers/specs/2026-09-01-fork-manifest-deployment-design.md`

## Global Constraints

- Pinned fork commit: `d658416d6b36381126eba4416877b6518c320921` — the value of `CLICKHOUSE_DEMO_FORK_REF`, and the **single source of truth**. The vendored manifest, `.env`, and the built images must all agree on it; `deploy-otel.sh` verifies this rather than trusting it.
- Fork repo: `https://github.com/ClickHouse/opentelemetry-demo.git` (`CLICKHOUSE_DEMO_FORK_REPO`).
- Local image name: `clickstack-local/ch-otel-demo`, tags `latest-<service>`. Never `clickhouse/ch-otel-demo` — the rename is what makes an accidental amd64 pull impossible.
- Host architecture is `arm64`; every built image must assert `linux/arm64`. An image that builds but reports the wrong architecture is a failure, not a pass.
- `otel-demo/upstream/` is verbatim vendored content. Never hand-edit it; all customisation lives in `otel-demo/kustomization.yaml`.
- Two source patches are applied to the *cloned* fork at build time, never to vendored files: `accounting`'s `TreatWarningsAsErrors`, and swapping the artillery Dockerfile. Both must fail loudly if they no longer apply.
- Cluster name comes from `CLUSTER_NAME` in `.env` (default `clickstack-local`); kubeconfig is `./.kube/config`.

---

### Task 1: Vendor the fork manifest

**Files:**
- Create: `scripts/refresh-demo-manifest.sh`
- Create (generated): `otel-demo/upstream/opentelemetry-demo.yaml`, `otel-demo/upstream/SOURCE`

**Interfaces:**
- Consumes: `CLICKHOUSE_DEMO_FORK_REPO`, `CLICKHOUSE_DEMO_FORK_REF` from `.env`.
- Produces: `otel-demo/upstream/opentelemetry-demo.yaml` (kustomize base) and `otel-demo/upstream/SOURCE`, whose `commit:` line later tasks parse with `awk '/^commit:/{print $2}'`.

- [ ] **Step 1: Write the failing check**

The check is that the vendored file exists and matches the fork byte for byte. Run it now, before the script exists:

```bash
test -f otel-demo/upstream/opentelemetry-demo.yaml && echo PRESENT || echo ABSENT
```

Expected: `ABSENT`

- [ ] **Step 2: Create `scripts/refresh-demo-manifest.sh`**

```bash
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
```

- [ ] **Step 3: Make it executable and run it**

```bash
chmod +x scripts/refresh-demo-manifest.sh
scripts/refresh-demo-manifest.sh d658416d6b36381126eba4416877b6518c320921
```

Expected: `Vendored kubernetes/opentelemetry-demo.yaml @ d658416d6b36 -> otel-demo/upstream/`

- [ ] **Step 4: Verify the copy is verbatim and parses**

```bash
curl -fsSL https://raw.githubusercontent.com/ClickHouse/opentelemetry-demo/d658416d6b36381126eba4416877b6518c320921/kubernetes/opentelemetry-demo.yaml \
  | shasum -a 256 | cut -d' ' -f1
shasum -a 256 otel-demo/upstream/opentelemetry-demo.yaml | cut -d' ' -f1
ruby -ryaml -e 'puts "docs: #{YAML.load_stream(File.read("otel-demo/upstream/opentelemetry-demo.yaml")).compact.size}"'
awk '/^commit:/{print $2}' otel-demo/upstream/SOURCE
```

Expected: the two checksums are identical; `docs: 53`; the commit line prints the full SHA.

- [ ] **Step 5: Commit**

```bash
git add scripts/refresh-demo-manifest.sh otel-demo/upstream/
git commit -m "Vendor the ClickHouse fork's k8s manifest at a pinned commit"
```

---

### Task 2: Kustomize overlay and its regression check

**Files:**
- Create: `otel-demo/kustomization.yaml`
- Create: `otel-demo/gateway-alias-service.yaml`
- Create: `otel-demo/hyperdx-secret.yaml`
- Create: `scripts/check-overlay.sh`

**Interfaces:**
- Consumes: `otel-demo/upstream/opentelemetry-demo.yaml` from Task 1.
- Produces: a renderable overlay at `otel-demo/` (`kubectl apply -k otel-demo/`), and `scripts/check-overlay.sh`, which exits non-zero if any overlay invariant breaks. Task 5's `deploy-otel.sh` calls it before applying.

- [ ] **Step 1: Write the failing check**

`scripts/check-overlay.sh` asserts the invariants that must hold after rendering. Write it first:

```bash
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
```

- [ ] **Step 2: Run the check to verify it fails**

```bash
chmod +x scripts/check-overlay.sh
scripts/check-overlay.sh
```

Expected: FAIL — `kubectl kustomize otel-demo/` errors because there is no `kustomization.yaml` yet.

- [ ] **Step 3: Create the two extra resources**

`otel-demo/gateway-alias-service.yaml`:

```yaml
# The fork's manifest sends all demo telemetry to a Service named
# "my-clickstack-otel-collector" (its OTEL_COLLECTOR_NAME). We do not run the
# ClickStack collector in-cluster — our gateway in the observability namespace is
# the only thing that talks to ClickHouse Cloud. This alias points that name at
# the gateway, so the fork manifest needs no edits at all.
apiVersion: v1
kind: Service
metadata:
  name: my-clickstack-otel-collector
  namespace: otel-demo
spec:
  type: ExternalName
  externalName: clickstack-gateway-opentelemetry-collector.observability.svc.cluster.local
```

`otel-demo/hyperdx-secret.yaml`:

```yaml
# The fork's frontend and payment initialise telemetry through
# @hyperdx/node-opentelemetry, whose init() hard-returns unless an api key or
# OTEL_EXPORTER_OTLP_HEADERS is present ("OpenTelemetry SDK initialization
# skipped") — no tracing SDK, no MeterProvider, and logs arrive with an empty
# TraceId. The manifest reads this Secret as optional; supplying it makes that
# code path deliberate instead of depending on Kubernetes leaving a literal
# "$(HYPERDX_API_KEY)" behind. The value is only ever sent as an Authorization
# header to our own collector, which does not authenticate.
apiVersion: v1
kind: Secret
metadata:
  name: hyperdx-secret
  namespace: otel-demo
type: Opaque
stringData:
  HYPERDX_API_KEY: local-collector-no-auth-required
```

- [ ] **Step 4: Create `otel-demo/kustomization.yaml`**

```yaml
# =============================================================================
# Our delta on top of ClickHouse's OTel-demo manifest.
# =============================================================================
# The base in upstream/ is a verbatim copy (see upstream/SOURCE) and is never
# edited. Everything we change lives here, so "what did we change vs the fork"
# stays a 40-line answer. scripts/check-overlay.sh asserts these still hold.
# =============================================================================
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: otel-demo

resources:
  - upstream/opentelemetry-demo.yaml
  - gateway-alias-service.yaml
  - hyperdx-secret.yaml

# All 19 fork images share one image NAME and differ only by tag, so a single
# entry retargets them to the copies we build for this host's architecture.
# The rename is deliberate: clickstack-local/ch-otel-demo does not exist on any
# registry, so no misconfiguration can pull the amd64 originals over our arm64
# builds.
images:
  - name: clickhouse/ch-otel-demo
    newName: clickstack-local/ch-otel-demo

patches:
  # Images are kind-loaded, not pulled. "Always" would fetch the upstream
  # amd64 image over ours and every pod would die with "exec format error".
  # Every Deployment has containers[0]; only flagd has a second container.
  - target:
      kind: Deployment
    patch: |
      - op: replace
        path: /spec/template/spec/containers/0/imagePullPolicy
        value: IfNotPresent
  - target:
      kind: Deployment
      name: flagd
    patch: |
      - op: replace
        path: /spec/template/spec/containers/1/imagePullPolicy
        value: IfNotPresent

  # The manifest ships CACHE_SIZE=100000, at which the Visa validation cache
  # never fills and the walkthrough's incident never fires. 10 fills within a
  # minute or two of checkout traffic.
  - patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: payment
      spec:
        template:
          spec:
            containers:
              - name: payment
                env:
                  - name: CACHE_SIZE
                    value: "10"

  # Jaeger is a second tracing backend we do not use; ClickHouse Cloud is the
  # backend. The prometheus ServiceAccount/RBAC is orphaned — the manifest
  # ships no prometheus workload.
  - target:
      name: "jaeger.*"
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: ignored
      $patch: delete
  - target:
      name: "prometheus"
    patch: |
      apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: ignored
      $patch: delete
```

- [ ] **Step 5: Run the check to verify it passes**

```bash
scripts/check-overlay.sh
```

Expected: `Overlay check OK: 19 local images, no Always pulls, CACHE_SIZE=10, jaeger removed, alias + secret present.`

- [ ] **Step 6: Sanity-check the rendered resource count**

```bash
kubectl kustomize otel-demo/ | ruby -ryaml -e 'puts "docs: #{YAML.load_stream($stdin.read).compact.size}"'
```

Expected: `docs: 46` (53 base − 8 deleted + 2 added, one of which replaces nothing).

- [ ] **Step 7: Commit**

```bash
git add otel-demo/kustomization.yaml otel-demo/gateway-alias-service.yaml otel-demo/hyperdx-secret.yaml scripts/check-overlay.sh
git commit -m "Add kustomize overlay for the fork manifest, with a regression check"
```

---

### Task 3: Our multi-arch artillery image

**Files:**
- Create: `otel-demo/artillery/Dockerfile`
- Create: `otel-demo/artillery/run.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `otel-demo/artillery/{Dockerfile,run.sh}`, which Task 4 copies over `src/artillery-load-generator/{Dockerfile,run.sh}` in the cloned fork before building. The Dockerfile builds against the fork's own build context, so it relies on `flows.js`, `load-test.template.yaml`, `package.json` and `package-lock.json` already being there.

- [ ] **Step 1: Write the failing check**

The check is that an image built from our Dockerfile reports arm64. Run it before the files exist:

```bash
test -f otel-demo/artillery/Dockerfile && echo PRESENT || echo ABSENT
```

Expected: `ABSENT`

- [ ] **Step 2: Create `otel-demo/artillery/run.sh`**

The fork's manifest overrides the container command and invokes this with `/bin/sh /app/run.sh`, so it must be POSIX — no bashisms.

```sh
#!/bin/sh
# Render the artillery scenario from env and run it once. The Deployment wraps
# this in a restart loop, so a single run is all we do here.
set -e

: "${ARRIVAL_COUNT:=1}"
: "${DURATION:=60}"

envsubst < load-test.template.yaml > load-test.yaml
exec artillery run load-test.yaml
```

- [ ] **Step 3: Create `otel-demo/artillery/Dockerfile`**

```dockerfile
# Replacement for the fork's src/artillery-load-generator/Dockerfile.
#
# The fork builds FROM artilleryio/artillery, which is amd64-only on all of its
# published tags, so the resulting image cannot run on an arm64 kind node — it
# builds "successfully" and then crash-loops with "exec format error". The
# Microsoft Playwright image is multi-arch and already ships the browsers the
# scenario drives, so we install the artillery CLI on top of it instead.
#
# Everything else — flows.js, load-test.template.yaml, the faker dependency —
# comes from the fork's own build context, unchanged.
FROM mcr.microsoft.com/playwright:v1.50.0-jammy

WORKDIR /app

RUN npm install -g artillery@2.0.34

COPY package.json package-lock.json ./
RUN npm install

RUN apt-get update \
 && apt-get install -y --no-install-recommends gettext-base \
 && rm -rf /var/lib/apt/lists/*

COPY flows.js load-test.template.yaml run.sh ./
RUN chmod +x run.sh

ENTRYPOINT ["/bin/sh", "./run.sh"]
```

- [ ] **Step 4: Build it against the fork's context and verify the architecture**

```bash
chmod +x otel-demo/artillery/run.sh
rm -rf /tmp/art-verify && mkdir -p /tmp/art-verify
git -C /tmp/art-verify init -q
git -C /tmp/art-verify remote add origin https://github.com/ClickHouse/opentelemetry-demo.git
git -C /tmp/art-verify config core.sparseCheckout true
printf '%s\n' 'src/artillery-load-generator/' > /tmp/art-verify/.git/info/sparse-checkout
git -C /tmp/art-verify fetch -q --depth 1 origin d658416d6b36381126eba4416877b6518c320921
git -C /tmp/art-verify checkout -q FETCH_HEAD
cp otel-demo/artillery/Dockerfile otel-demo/artillery/run.sh /tmp/art-verify/src/artillery-load-generator/
docker build -q -t clickstack-local/ch-otel-demo:latest-artillery /tmp/art-verify/src/artillery-load-generator
docker image inspect clickstack-local/ch-otel-demo:latest-artillery --format '{{.Os}}/{{.Architecture}}'
```

Expected: the final line prints `linux/arm64`.

- [ ] **Step 5: Commit**

```bash
git add otel-demo/artillery/
git commit -m "Add a multi-arch artillery image to replace the amd64-only base"
```

---

### Task 4: Build and load all demo images

**Files:**
- Create: `scripts/build-demo-images.sh`
- Modify: `scripts/preflight.sh` (add `docker compose` and kustomize checks)

**Interfaces:**
- Consumes: `CLICKHOUSE_DEMO_FORK_REPO`, `CLICKHOUSE_DEMO_FORK_REF`, `CLUSTER_NAME` from `.env`; `otel-demo/artillery/{Dockerfile,run.sh}` from Task 3.
- Produces: 19 images tagged `clickstack-local/ch-otel-demo:latest-<service>` loaded into the kind cluster, and the marker file `.cache/demo-images.sha` containing the fork SHA they were built from. Task 5's `deploy-otel.sh` reads that marker.

- [ ] **Step 1: Write the failing check**

```bash
cat .cache/demo-images.sha 2>/dev/null || echo "NO MARKER"
```

Expected: `NO MARKER`

- [ ] **Step 2: Create `scripts/build-demo-images.sh`**

```bash
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
```

- [ ] **Step 3: Add the new prerequisites to `scripts/preflight.sh`**

Insert immediately before the final `echo "Preflight OK: ..."` line:

```bash
# --- docker compose (used to build the demo-fork images) ---------------------
docker compose version >/dev/null 2>&1 \
  || fail "'docker compose' not available. Update Docker Desktop and retry."

# --- kustomize (built into kubectl v1.14+; we rely on v5 patch semantics) ----
kubectl kustomize --help >/dev/null 2>&1 \
  || fail "'kubectl kustomize' not available. Update kubectl and retry."
```

and change the final line to:

```bash
echo "Preflight OK: docker running; kind, kubectl (with kustomize), helm, docker compose, envsubst, jq, git available."
```

- [ ] **Step 4: Run the build**

```bash
chmod +x scripts/build-demo-images.sh
scripts/build-demo-images.sh
```

Expected: 19 lines all reading `ok`, then `All 19 images verified linux/arm64.`, then the load, then `Done.` Note the images from the design spike are already in the Docker cache, so most services rebuild from cache in seconds.

- [ ] **Step 5: Verify the marker and the loaded images**

```bash
cat .cache/demo-images.sha
docker exec clickstack-local-worker crictl images 2>/dev/null | grep -c 'clickstack-local/ch-otel-demo'
```

Expected: the pinned SHA; and `19`.

- [ ] **Step 6: Commit**

```bash
git add scripts/build-demo-images.sh scripts/preflight.sh
git commit -m "Build and kind-load the fork's 19 service images for the host arch"
```

---

### Task 5: Switch deployment to the overlay

**Files:**
- Modify: `scripts/deploy-otel.sh` (replace everything from the scenario resolution through the demo install)
- Modify: `scripts/teardown-otel.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `.cache/demo-images.sha` (Task 4), `otel-demo/upstream/SOURCE` (Task 1), `scripts/check-overlay.sh` (Task 2).
- Produces: `make demo-images` and a `make otel-up` that applies the overlay. `make otel-scenarios` ceases to exist.

- [ ] **Step 1: Write the failing check**

```bash
grep -c 'kubectl apply -k otel-demo/' scripts/deploy-otel.sh || true
```

Expected: `0`

- [ ] **Step 2: Rewrite the demo half of `scripts/deploy-otel.sh`**

Keep everything up to and including the two agent `helm upgrade --install` lines. Delete the chart pin, the `helm pull`, the whole scenario resolution/validation block, the flagd ConfigMap handling, the Visa-cache image build, the envsubst rendering, the demo `helm upgrade`, and the flags-changed restart block. Replace the demo section with:

```bash
# --- OTel Demo (ClickHouse fork manifest) ------------------------------------
# The demo is no longer a Helm chart: we apply the fork's own manifest, vendored
# verbatim under otel-demo/upstream/ and customised by otel-demo/kustomization.yaml.
# Its images are built locally for this architecture by scripts/build-demo-images.sh,
# because the fork publishes amd64 only.

# A manifest from one commit with images from another is the most likely way this
# breaks subtly, so all three sources of the fork version must agree.
MANIFEST_SHA="$(awk '/^commit:/{print $2}' otel-demo/upstream/SOURCE)"
IMAGES_SHA="$(cat .cache/demo-images.sha 2>/dev/null || true)"

if [ "$MANIFEST_SHA" != "$CLICKHOUSE_DEMO_FORK_REF" ]; then
  echo "ERROR: vendored manifest is from ${MANIFEST_SHA:0:12} but CLICKHOUSE_DEMO_FORK_REF" >&2
  echo "       is ${CLICKHOUSE_DEMO_FORK_REF:0:12}. Run: scripts/refresh-demo-manifest.sh" >&2
  exit 1
fi
if [ -z "$IMAGES_SHA" ]; then
  echo "ERROR: demo images have not been built. Run: make demo-images" >&2
  exit 1
fi
if [ "$IMAGES_SHA" != "$CLICKHOUSE_DEMO_FORK_REF" ]; then
  echo "ERROR: demo images were built from ${IMAGES_SHA:0:12} but CLICKHOUSE_DEMO_FORK_REF" >&2
  echo "       is ${CLICKHOUSE_DEMO_FORK_REF:0:12}. Run: make demo-images" >&2
  exit 1
fi

# The demo used to be a Helm release. Helm and kubectl fight over ownership of the
# same object names, so refuse to apply on top of one rather than half-converting.
if helm status otel-demo -n otel-demo >/dev/null 2>&1; then
  echo "ERROR: an old Helm release 'otel-demo' is still installed. Remove it first:" >&2
  echo "         make otel-down" >&2
  exit 1
fi

scripts/check-overlay.sh
kubectl apply -k otel-demo/

echo
echo "OTel pipeline deployed. Check status with: make otel-status"
echo "Failure scenarios are the fork's flagd defaults (paymentCacheLeak on)."
echo "Toggle them in the flagd-ui: kubectl -n otel-demo port-forward deploy/flagd 4000:4000"
```

- [ ] **Step 3: Update `scripts/teardown-otel.sh`**

Replace the `helm uninstall otel-demo` line with an overlay delete, and drop the rendered-values cleanup:

```bash
kubectl delete -k otel-demo/ --ignore-not-found 2>/dev/null || true
helm uninstall otel-demo -n otel-demo 2>/dev/null || true   # legacy chart installs
```

and delete this line:

```bash
rm -f otel/.otel-demo-values.rendered.yaml
```

- [ ] **Step 4: Update the `Makefile`**

Replace the `otel-up` and `otel-scenarios` targets, and update `.PHONY`:

```make
.PHONY: help up down recreate pause resume status kubeconfig demo-images otel-up otel-down otel-status hyperdx-sources ingress-up ingress-down ingress-status

demo-images: ## Build the demo-fork service images for this arch and load them into kind (~12 min first run)
	@scripts/build-demo-images.sh

otel-up: ## Deploy the OTel pipeline + demo (run make demo-images first)
	@scripts/deploy-otel.sh
```

- [ ] **Step 5: Remove the old Helm release, then deploy**

```bash
make otel-down
make otel-up
```

Expected: `Overlay check OK: ...`, a list of created resources, then `OTel pipeline deployed.`

- [ ] **Step 6: Verify the deployment converges**

```bash
kubectl -n otel-demo wait --for=condition=Available deploy --all --timeout=300s
kubectl -n otel-demo get pods
kubectl -n otel-demo get pods -o json \
  | ruby -rjson -e 'p JSON.parse($stdin.read)["items"].flat_map{|i| (i.dig("status","containerStatuses")||[]).map{|c| c.dig("state","waiting","reason") || c.dig("lastState","terminated","reason")}}.compact.uniq'
```

Expected: all Deployments Available; no `ImagePullBackOff`, no `ErrImagePull`, no `CrashLoopBackOff`, no `OOMKilled`.

- [ ] **Step 7: Commit**

```bash
git add scripts/deploy-otel.sh scripts/teardown-otel.sh Makefile
git commit -m "Deploy the demo from the fork manifest instead of the upstream chart"
```

---

### Task 6: Delete the chart-era files

**Files:**
- Delete: `otel/otel-demo-values.yaml`, `otel/otel-demo-visa-cache-values.yaml`, `otel/flagd-extra-flags.json`, `scripts/list-scenarios.sh`
- Modify: `.env.example`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing new; this is removal only. Run it after Task 5 proves the replacement works.

- [ ] **Step 1: Confirm nothing still references them**

```bash
grep -rn 'otel-demo-values\|otel-demo-visa-cache-values\|flagd-extra-flags\|list-scenarios\|SCENARIOS\|DEMO_CHART_VERSION\|VISA_CACHE_SIZE' \
  --include='*.sh' --include='Makefile' --include='*.yaml' . | grep -v '^./docs/' || echo "NO REFERENCES"
```

Expected: `NO REFERENCES`. If anything appears outside `docs/`, fix it before deleting.

- [ ] **Step 2: Delete the files**

```bash
git rm otel/otel-demo-values.yaml otel/otel-demo-visa-cache-values.yaml otel/flagd-extra-flags.json scripts/list-scenarios.sh
```

- [ ] **Step 3: Update the fork section of `.env.example`**

Replace the block headed `# --- "Visa cache full" scenario (make otel-up SCENARIOS=paymentCacheLeak) ---` with:

```bash
# --- OTel Demo images (make demo-images) -------------------------------------
# The demo is deployed from ClickHouse's fork manifest (otel-demo/), and its
# service images are built locally: the fork publishes amd64-only images, which
# cannot run on Apple Silicon. This SHA is the single source of truth for the
# fork version — the vendored manifest in otel-demo/upstream/, the built images,
# and this value must agree, and make otel-up refuses to deploy if they do not.
# To move to a newer fork revision:
#   1. update CLICKHOUSE_DEMO_FORK_REF here and in your .env
#   2. scripts/refresh-demo-manifest.sh      (re-vendors the manifest; review the diff)
#   3. make demo-images                      (rebuilds and reloads the images)
CLICKHOUSE_DEMO_FORK_REPO=https://github.com/ClickHouse/opentelemetry-demo.git
CLICKHOUSE_DEMO_FORK_REF=d658416d6b36381126eba4416877b6518c320921
```

- [ ] **Step 4: Update your local `.env` to match**

`.env` is gitignored, so this is a local step that is easy to forget — and `make otel-up` will fail loudly until it is done.

```bash
sed -i.bak 's/^CLICKHOUSE_DEMO_FORK_REF=.*/CLICKHOUSE_DEMO_FORK_REF=d658416d6b36381126eba4416877b6518c320921/' .env
rm -f .env.bak
grep CLICKHOUSE_DEMO_FORK_REF .env
```

Expected: the new SHA.

- [ ] **Step 5: Verify the pipeline still deploys clean**

```bash
scripts/check-overlay.sh && make otel-up
```

Expected: overlay check OK, resources unchanged or configured, no errors.

- [ ] **Step 6: Commit**

```bash
git add -A .env.example otel scripts
git commit -m "Remove the chart-era values, flag catalog and scenarios script"
```

---

### Task 7: Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-15-configurable-failure-scenarios-design.md`
- Modify: `docs/superpowers/specs/2026-07-20-visa-cache-scenario-design.md`

**Interfaces:**
- Consumes: the behaviour built in Tasks 1–6.
- Produces: documentation only.

- [ ] **Step 1: Mark the two superseded specs**

Add immediately under the `**Status:**` line of each:

```markdown
**Superseded by:** `docs/superpowers/specs/2026-09-01-fork-manifest-deployment-design.md`
(2026-09-01). The SCENARIOS interface and the three-image fork overlay described
here no longer exist: the demo is deployed from the fork's own manifest with all
19 images built locally, and failure flags come from the fork's flagd defaults.
Kept for the reasoning it records.
```

- [ ] **Step 2: Rewrite the OTel section of `CLAUDE.md`**

Replace the "Failure scenarios", "Visa cache full scenario" and chart-era "Gotchas" subsections with:

```markdown
### OTel Demo (fork manifest)
The demo is deployed from **ClickHouse's fork manifest**, not the upstream Helm chart:
`otel-demo/upstream/opentelemetry-demo.yaml` is a verbatim copy pinned to
`CLICKHOUSE_DEMO_FORK_REF`, customised by `otel-demo/kustomization.yaml` and applied with
`kubectl apply -k otel-demo/`. `scripts/check-overlay.sh` asserts the overlay's invariants
and runs on every deploy.

- **Images are built locally.** The fork publishes **amd64-only** images, so
  `make demo-images` builds all 19 services from source for this host
  (`clickstack-local/ch-otel-demo:latest-*`) and `kind load`s them. ~12 min first run,
  cached after. `make otel-up` refuses to deploy if the images, the vendored manifest and
  `.env` disagree on the fork SHA.
- **Two source patches** are applied to the clone at build time, never to vendored files,
  and both fail loudly if they stop applying: `accounting`'s `TreatWarningsAsErrors`
  (NuGet audit at level `low` turns post-hoc advisories into build errors — this breaks on
  amd64 too), and the artillery Dockerfile (its `artilleryio/artillery` base is amd64-only
  on every tag; we build on `mcr.microsoft.com/playwright` instead).
- **No demo collector.** The fork's design has apps export straight to the ClickStack
  collector, so an `ExternalName` Service aliases `my-clickstack-otel-collector` to our
  gateway. There is no spanmetrics; HyperDX derives service health from traces. If we ever
  want spanmetrics it belongs in the gateway.
- **Failure scenarios** are the fork's flagd defaults (`paymentCacheLeak` on). There is no
  `SCENARIOS` variable any more — toggle flags interactively in the flagd-ui
  (`kubectl -n otel-demo port-forward deploy/flagd 4000:4000`).
- **Upgrading the fork:** bump `CLICKHOUSE_DEMO_FORK_REF`, run
  `scripts/refresh-demo-manifest.sh`, review the `git diff` of `otel-demo/upstream/`, then
  `make demo-images`.
```

- [ ] **Step 3: Update `README.md`**

- In "Make targets", add `demo-images` and remove `otel-scenarios`.
- In "Quick start" and "OpenTelemetry collection", make `make demo-images` an explicit step before `make otel-up`, noting the one-off ~12 minute cost.
- Replace the "Failure scenarios" and "Visa cache full incident" sections with the flagd-defaults description from Step 2.
- In "Option 2 — raw helm/kubectl", replace the demo `helm upgrade` line with `kubectl apply -k otel-demo/`.
- In "Notes / gotchas", delete the chart hostPort, demo-collector preset, flagd ownership, SDK endpoint and browser-traffic entries; they describe machinery that no longer exists.

- [ ] **Step 4: Check the docs match reality**

```bash
grep -rn 'SCENARIOS\|otel-scenarios\|DEMO_CHART_VERSION\|otel-demo-values' README.md CLAUDE.md || echo "NO STALE REFERENCES"
grep -n 'demo-images' README.md CLAUDE.md Makefile | head
```

Expected: `NO STALE REFERENCES`, and `demo-images` present in all three.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md docs/superpowers/specs/
git commit -m "Document the fork-manifest deployment; supersede the chart-era specs"
```

---

### Task 8: End-to-end verification

**Files:** none — this task changes nothing. It is the gate that says the migration actually worked.

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: a verification record to paste into the PR description.

- [ ] **Step 1: Rebuild the world from scratch**

```bash
make otel-down
make demo-images
make otel-up
make ingress-up
```

Expected: each completes without error.

- [ ] **Step 2: Confirm every workload is healthy**

```bash
kubectl -n otel-demo wait --for=condition=Available deploy --all --timeout=300s
kubectl -n otel-demo get pods
```

Expected: all Available; no restarts climbing, no `OOMKilled`. If `checkout` OOMs as it did under the chart, record the limit the manifest sets and raise it in the overlay.

- [ ] **Step 3: Confirm the storefront serves**

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080
```

Expected: `200`

- [ ] **Step 4: Confirm telemetry reaches the gateway**

```bash
kubectl -n observability logs deploy/clickstack-gateway-opentelemetry-collector --tail=50 | grep -iE 'error|refused' || echo "NO EXPORT ERRORS"
```

Expected: `NO EXPORT ERRORS`.

- [ ] **Step 5: Confirm the Visa incident fires**

Give it a few minutes of traffic, then:

```bash
kubectl -n otel-demo logs deploy/payment --tail=200 | grep -c 'Visa cache full'
kubectl -n otel-demo logs deploy/frontend --tail=200 | grep -c 'Failed to place order'
```

Expected: both greater than zero.

- [ ] **Step 6: Confirm the walkthrough signals in HyperDX**

In the HyperDX UI, confirm: the `Failed to place order` log has a populated `TraceId` and a working Trace button (step 8); the `visa_validation_cache.size` gauge charts (step 13); and note whether artillery's browser traffic produced any Sessions data.

- [ ] **Step 7: Confirm artillery is actually running**

```bash
kubectl -n otel-demo logs deploy/artillery-loadgen --tail=30
```

Expected: artillery summary reports with `vusers.completed` greater than zero and `browser.page.codes.200` present. `exec format error` here means the wrong architecture was loaded.

- [ ] **Step 8: Open the pull request**

```bash
git push -u origin fork-manifest-deployment
gh pr create --title "Deploy the OTel Demo from ClickHouse's fork manifest" --body "<verification record from steps 1-7>"
```
