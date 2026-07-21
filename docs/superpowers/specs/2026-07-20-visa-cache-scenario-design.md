# Design: "Visa cache full" scenario (`SCENARIOS=paymentCacheLeak`)

**Date:** 2026-07-20
**Status:** approved (design)

## Problem

The ClickStack `remote-demo-data` walkthrough is built around a **"Visa cache full:
cannot add new item"** payment incident (surfaced to users as a failed order / "Failed
to place order"). That scenario does **not exist in the stock OpenTelemetry demo** (any
version, including `main`) — it lives only in ClickHouse's fork
`ClickHouse/opentelemetry-demo`, captured into the pre-recorded dataset replayed on
`sql.clickhouse.com`. This repo deploys the **stock** demo chart, so its payment service
throws `Payment request failed. Invalid token. app.loyalty.level=gold` instead, and the
walkthrough can't be reproduced live in the user's own ClickStack.

Goal: an opt-in way to run the genuine "Visa cache full" incident live in the local
cluster, folded into the existing `SCENARIOS` mechanism.

## Research findings (fork @ `15969bb…`)

- Gated by a boolean flagd flag **`paymentCacheLeak`** (`variants {on,off}`, fork default
  `on`) — absent from the stock flag catalog.
- `src/payment/charge.js`: an unbounded `visaValidationCache`; once it reaches `CACHE_SIZE`
  (env, default `1000`) every new **distinct Visa** number throws `Visa cache full: cannot
  add new item.` (repeats of the same number are cache hits).
- The fork **load generator** sends random **distinct** Visa numbers (`generate_credit_card()`,
  ~80% Visa); the stock loadgen uses a fixed card and can never fill the cache.
- **Minimum to fire:** fork **payment** image + fork **load-generator** image +
  `paymentCacheLeak=on` + a low-ish `CACHE_SIZE`. flagd binary and frontend stay stock.
- Fork tracks ~2.2.0 (matches our chart), so the payment↔checkout gRPC proto contract is
  compatible with our stock chart → low version-skew risk.
- The fork's published images (`clickhouse/ch-otel-demo:latest-*`) are **amd64-only**; the
  host is arm64 → build locally for the host arch and `kind load`.

## Approach

Surgical two-service swap on top of the stock chart, triggered by selecting
`paymentCacheLeak` in `SCENARIOS`. Everything else (gateway, agents, ingress, flag
delta-patch, browser-traffic-off, infra-preset-off) is unchanged. Rejected deploying the
whole fork: on arm64 it would rebuild/emulate ~20 services and lose our Helm-values
customizations, for no added fidelity to this incident.

`make otel-up SCENARIOS=paymentCacheLeak` → builds+loads the fork `payment` +
`load-generator` images for the host arch, overrides those two components' images (+ low
`CACHE_SIZE` on payment), and injects `paymentCacheLeak=on`. Composable, e.g.
`SCENARIOS="paymentCacheLeak paymentFailure=25%"`. Any selection **without**
`paymentCacheLeak` is unchanged (stock images, no fork build).

## Components

| File | Change |
|------|--------|
| `.env.example` | Document `CLICKHOUSE_DEMO_FORK_REPO`/`_REF` (pinned SHA) — optional; `deploy-otel.sh` defaults them. |
| `otel/flagd-extra-flags.json` (new) | Fork-only flag defs not in the stock catalog (`paymentCacheLeak`), merged into the catalog so it's selectable/validatable. |
| `otel/otel-demo-visa-cache-values.yaml` (new) | Helm overlay (extra `-f`, only when selected): `imageOverride` for payment + load-generator, `CACHE_SIZE` on payment, `pullPolicy: IfNotPresent`. envsubst template. |
| `scripts/deploy-otel.sh` | Merge extra flags into `$FLAG_SRC`; detect `paymentCacheLeak` in the selection (`VISA_CACHE`); sparse+shallow-clone the pinned fork, `docker build` both images, `kind load` (idempotent); render the overlay + add it as a second `-f`. Reuses existing delta-patch + change-detection + consumer-restart blocks. |
| `scripts/list-scenarios.sh` | Merge extra flags so `make otel-scenarios` lists `paymentCacheLeak` (with a note that it swaps in fork images). |
| `scripts/preflight.sh` | Ensure `git`. |
| `CLAUDE.md`, `README.md`, `.gitignore` | Document the scenario; ignore `.cache/`. |

## Key reuse
- `deploy-otel.sh` existing `$FLAG_SRC` / `SEL_JSON` / `$PATCHED`, `FLAGS_CHANGED`
  change-detection, and flagd/consumer-restart logic slot this in directly.
- The chart's per-component `imageOverride` / `envOverrides`.

## Verification
1. `make otel-up SCENARIOS=paymentCacheLeak`: `payment` + `load-generator` run the locally
   built host-arch images (no `exec format error`), Ready.
2. `paymentCacheLeak` served `on` via flagd OFREP; `make otel-scenarios` lists it.
3. Checkout works initially (proto compatibility): some successful `PlaceOrder` spans.
4. After enough distinct Visa checkouts exceed `CACHE_SIZE`, ClickHouse `default.otel_traces`
   shows checkout/payment errors carrying `Visa cache full: cannot add new item.`
5. Composability: `SCENARIOS="paymentCacheLeak paymentFailure=25%"` applies both.
6. Regression: plain `make otel-up` (no paymentCacheLeak) deploys **stock** images and
   triggers **no** fork build; `SCENARIOS=none` healthy.
7. Idempotent re-run doesn't rebuild images.

## Out of scope
- Deploying the full ClickHouse fork / its HyperDX browser SDK (session replay).
- amd64 emulation (we build natively for the host arch instead).
