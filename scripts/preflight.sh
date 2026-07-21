#!/usr/bin/env bash
# Verify (and, where possible, install) everything needed to run the cluster.
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- Docker daemon -----------------------------------------------------------
if ! docker info >/dev/null 2>&1; then
  fail "Docker is not running. Start Docker Desktop (open -a Docker) and retry."
fi

# --- Homebrew ----------------------------------------------------------------
command -v brew >/dev/null 2>&1 || fail "Homebrew not found. Install from https://brew.sh and retry."

# --- Required CLIs (install via brew if missing) -----------------------------
# gettext provides envsubst (keg-only on macOS, so we resolve its path directly).
ensure() {
  local cmd="$1" formula="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Installing $formula (provides $cmd)..."
    brew install "$formula"
  fi
}

ensure kind kind
ensure kubectl kubectl
ensure helm helm
ensure jq jq
ensure git git

if ! command -v envsubst >/dev/null 2>&1; then
  echo "Installing gettext (provides envsubst)..."
  brew install gettext
fi

echo "Preflight OK: docker running; kind, kubectl, helm, envsubst, jq, git available."
