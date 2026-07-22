# Design: replicate the ClickStack remote-demo walkthrough (steps 1–13)

**Date:** 2026-07-22
**Status:** approved (design)

## Problem

Following the ClickStack `remote-demo-data` walkthrough against the user's **own** Managed
ClickStack + local cluster, three things are missing: (a) no `Failed to place order` log
from `frontend`, (b) no "view a trace" option, (c) no metrics table. Research established:

- The walkthrough reads **four HyperDX data sources** — Logs, Traces, Metrics, Sessions —
  and **none are auto-created for a user's own ClickHouse**. (b) and (c) are almost entirely
  **HyperDX source-configuration** gaps, not data gaps: the ClickStack collector creates the
  ClickHouse *tables*, but a HyperDX *source* (app config mapping a signal → table + columns
  + cross-signal correlation) is a separate object HyperDX only auto-provisions in its
  all-in-one/local mode, not for an externally-written ClickHouse.
- `Failed to place order` is a **server-side log** in the **fork** frontend's
  `src/frontend/pages/api/checkout.ts`. The **stock** upstream frontend's checkout route has
  **no error handling** (verified) and never logs it. The user runs the stock frontend
  (PR #4 swapped only payment + load-generator).
- The metrics-step gauge (`visa_validation_cache.size`) comes from the fork payment (PR #4).

Scope decision: **Core (steps 1–13)** now; session replay (14–15) → GitHub issue; HyperDX
source setup delivered as **both** a script and UI steps.

## Approach

Two parts: (1) generate every signal the walkthrough reads by folding the **fork frontend**
into the existing `paymentCacheLeak` scenario (alongside the fork payment/load-generator it
already swaps); (2) configure the four HyperDX sources in the user's Managed ClickStack via a
best-effort script + authoritative UI steps.

Builds on the merged `paymentCacheLeak` scenario (PR #4).

## Changes

- `scripts/deploy-otel.sh` — when `VISA_CACHE=1`, also build + `kind load` the fork
  **`frontend`** image (add `src/frontend/` to the sparse checkout; its Dockerfile needs only
  that dir) and include it in the overlay render vars (`VISA_FRONTEND_REPO`).
- `otel/otel-demo-visa-cache-values.yaml` — add `components.frontend.imageOverride`. (Browser
  SDK left unconfigured for Core; the `Failed to place order` **server** log flows via the
  normal OTLP path.)
- `scripts/configure-hyperdx-sources.sh` (new) + `make hyperdx-sources` — checks ClickHouse
  readiness (table row counts), prints the exact source settings, and (with `--apply`/`APPLY=1`
  + `HYPERDX_API_URL`/`HYPERDX_API_KEY`) best-effort-creates the Logs/Traces/Metrics/Sessions
  sources via the HyperDX External API, reusing an existing ClickHouse connection.
- `.env.example` — optional `HYPERDX_API_URL` + `HYPERDX_API_KEY` (Personal API key).
- Docs — README "Replicate the ClickStack walkthrough" (deploy → sources → UI source table →
  step mapping; sessions caveat) + CLAUDE.md; this spec.
- GitHub issue — session replay (steps 14–15): browser RUM (fork frontend browser SDK +
  ingestion endpoint/key), a Playwright browser-traffic driver, Sessions source populated.

## Important constraint (documented, not worked around)

The HyperDX source-**create** API is **not** in the published OpenAPI spec (only the
*connection* schema + `GET /api/v2/sources` are documented). The script's create calls are
therefore **best-effort and unverified** (no test instance); they degrade gracefully to
printing the exact values. The **UI steps (Team Settings → Sources) are the verified path**,
which is why "Both" is delivered with the UI as authoritative.

## Verification
1. `make otel-up SCENARIOS=paymentCacheLeak` → `frontend`, `payment`, `load-generator` run the
   fork images (arm64), pods Ready.
2. ClickHouse `default.otel_logs` has `frontend` `Failed to place order`; `otel_traces` has the
   failing checkout spans; `otel_metrics_gauge` has `visa_validation_cache.size`.
3. `make hyperdx-sources` prints readiness (non-zero row counts) + source settings.
4. In HyperDX (after sources are set): `Failed to place order` error cluster (step 6), working
   `Trace` button on a log (step 8), a `visa_validation_cache.size (gauge)` chart (step 13).
5. Regression: plain `make otel-up` unaffected (stock frontend, no fork build).

## Verified outcome
On the live cluster with `SCENARIOS=paymentCacheLeak`: `Failed to place order` frontend
logs (16 in a 4-min window) and `Visa cache full` checkout traces (22) confirmed in
ClickHouse; fork frontend/payment/load-generator run their arm64 images (0 restarts).

## Known limitations (→ GitHub issues)
- **Step 13 gauge** (`visa_validation_cache.size`): the fork Node payment doesn't export app
  metrics in this setup (verified: 0 rows even with `OTEL_METRICS_EXPORTER=otlp`; other
  services' app metrics do flow). Steps 1–12 + the metrics source (infra/kafka/postgres/Java)
  work.
- **Session replay (steps 14–15)**: browser RUM — SDK wiring + ingestion, browser-traffic
  driver, Sessions source population.
