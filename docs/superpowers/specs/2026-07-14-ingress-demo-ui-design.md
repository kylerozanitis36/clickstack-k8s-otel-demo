# Design: expose the OTel Demo UI on `localhost:8080` via ingress-nginx

**Date:** 2026-07-14
**Status:** approved (design)

## Problem

Following the README, the cluster and OTel pipeline come up healthy, but
`http://localhost:8080` returns "Failed to Load Page". Root cause: kind publishes
host `8080 -> control-plane node :80` (see `kind/cluster-config.yaml`
`extraPortMappings`), but **nothing inside the cluster listens on node port 80** —
no ingress controller, no NodePort/hostPort service. The config comment states the
mapping is "reserved for a *future* ingress controller." The OTel Demo UI is served
by the `frontend-proxy` service, a **ClusterIP** on port 8080, unreachable from the
host. So the host connection is accepted by Docker's forward and immediately dropped
("Empty reply from server").

The demo app itself is healthy — a direct `port-forward svc/frontend-proxy` returns
HTTP 200. This is purely a routing gap: the "future ingress controller" was never
built.

## Goal

Make `http://localhost:8080` serve the OTel Demo UI, fulfilling the reserved-port
design, in a way that is declarative, idempotent, and reproducible — matching the
existing `otel-*` workflow.

## Approach

Deploy the **ingress-nginx** controller using kind's purpose-built manifest (pinned
to `controller-v1.15.1`). That manifest binds `hostPort` 80/443 and tolerates the
control-plane taint. An `Ingress` then routes `/` to the existing `frontend-proxy`
service.

Traffic path:
`localhost:8080` -> Docker publish -> control-plane node :80 -> nginx controller
-> Ingress -> `frontend-proxy:8080` -> demo UI.

### Why not Helm

The repo uses Helm for OTel, but kind's static ingress-nginx manifest already sets
the hostPort, nodeSelector, and tolerations correctly for kind. Reproducing that via
Helm values is strictly more config for the same result. We pin the manifest to a
released controller version to keep with the repo's pin-everything convention.

### Pinning the controller to the control-plane node

Host port 80 is mapped to the host only on the **control-plane** node (that is where
`extraPortMappings` live), so the controller must run there. Older kind ingress-nginx
manifests used a `nodeSelector: ingress-ready=true` for this; **v1.15.1 dropped it**
and only requires `kubernetes.io/os=linux`, so on this multi-node cluster the
controller could otherwise land on a worker with no host mapping. The deploy script
therefore patches the controller Deployment's `nodeSelector` to include the existing
`node-role.kubernetes.io/control-plane` label (empty value); the manifest already
tolerates the matching control-plane taint. This needs **no custom node label and no
cluster recreate**, and a fresh `make up && make ingress-up` still works because the
patch is idempotent. We deliberately do **not** edit `kind/cluster-config.yaml`.

### Version pinning

k8s here is v1.36.1, newer than any ingress-nginx release officially tests against.
We pin the newest ingress-nginx release in the script and **verify at deploy time**
by waiting for the controller pod to reach `Ready`. If incompatible, surface it and
bump the pin.

## Components (new)

| File | Purpose |
|------|---------|
| `ingress/frontend-ingress.yaml` | `Ingress` (class `nginx`, catch-all `/` -> `frontend-proxy:8080` in `otel-demo`). |
| `scripts/deploy-ingress.sh` | Preflight, label control-plane node, apply pinned ingress-nginx manifest, wait for controller `Ready`, verify `frontend-proxy` exists, apply the Ingress, verify HTTP 200. Idempotent. |
| `scripts/teardown-ingress.sh` | Delete the Ingress and the ingress-nginx controller. |
| `Makefile` | `ingress-up` / `ingress-down` / `ingress-status` targets. |
| README + CLAUDE.md | Document `make otel-up && make ingress-up` -> open `http://localhost:8080`. |

## Sequencing / dependencies

`ingress-up` runs **after** `make otel-up` (the Ingress targets `frontend-proxy`,
created by the demo). `deploy-ingress.sh` checks that service exists first and prints
a clear, actionable error if not.

## Error handling

- `deploy-ingress.sh` uses `set -euo pipefail`, reuses `scripts/preflight.sh`.
- Fails fast with a readable message if `frontend-proxy` is absent (demo not deployed).
- Waits for the ingress-nginx controller Deployment/admission to be `Ready` before
  applying the Ingress (avoids admission-webhook races).

## Verification

1. Controller pod `Ready` in `ingress-nginx` namespace.
2. `curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/` returns `200`.
3. Loading `http://localhost:8080` in a browser shows the demo storefront.

## Out of scope

- TLS on `:8443` (left reserved as before).
- Exposing collector/HyperDX endpoints via ingress.
- Baking the node label into `cluster-config.yaml` (optional future declarative tidy-up).
