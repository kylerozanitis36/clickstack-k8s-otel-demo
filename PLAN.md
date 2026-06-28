# Plan: Host a Local Kubernetes Cluster on macOS (kind)

## Context
This is the first step of the `clickstack-k8s-otel-demo` project: stand up a local Kubernetes
cluster on a MacBook Pro so we can later collect logs/metrics/traces from it with an
OpenTelemetry collector and ship them to ClickHouse Cloud / ClickStack (HyperDX).

The cluster must be **declarative and reproducible** so colleagues can recreate it
from checked-in config + a `.env`. Based on research and user decisions:

- **Tool: `kind`** (Kubernetes-in-Docker) — vanilla upstream k8s, fully config-file
  driven, trivial multi-node, de-facto standard for OTel demos.
- **Runtime: Docker Desktop** — already installed on this machine (just needs to be running).
- **Topology: multi-node** — 1 control-plane + 2 workers, so node-level telemetry
  (per-node logs/metrics via an OTel DaemonSet) is meaningful later.

Environment confirmed: Apple Silicon (arm64), 48 GB RAM, Homebrew present, `kubectl`
present, Docker Desktop installed (daemon currently stopped), `kind`/`helm` not yet installed.

Pinned for reproducibility (kind v0.32.0 / k8s 1.36.1):
`kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5`

## Files to Create
```
clickstack-k8s-otel-demo/
├── PLAN.md                     # human-readable runbook (copy of this plan, per user request)
├── README.md                  # quickstart + prerequisites
├── .gitignore                 # ignores .env, rendered config, local kubeconfig
├── .env.example               # committed template
├── .env                       # local, gitignored (copied from .env.example)
├── Makefile                   # primary UX: up / down / recreate / status / kubeconfig
├── kind/
│   └── cluster-config.yaml    # kind Cluster manifest template (envsubst placeholders)
└── scripts/
    ├── preflight.sh           # verify Docker running; install kind/helm via brew if missing
    ├── create-cluster.sh      # source .env, render config, kind create cluster
    └── delete-cluster.sh      # kind delete cluster
```

### `.env.example` (and `.env` copied from it)
```dotenv
# Cluster identity
CLUSTER_NAME=clickstack-local
# Pinned kind node image (kind v0.32.0 / k8s 1.36.1) for reproducible recreates
KIND_NODE_IMAGE=kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
# Project-local kubeconfig keeps the cluster isolated from ~/.kube/config
KUBECONFIG=./.kube/config
```

### `kind/cluster-config.yaml` (template rendered with `envsubst`)
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    image: ${KIND_NODE_IMAGE}
    # Reserve host ports for a future ingress controller (OTel/HyperDX exposure)
    extraPortMappings:
      - { containerPort: 80,  hostPort: 8080, protocol: TCP }
      - { containerPort: 443, hostPort: 8443, protocol: TCP }
  - role: worker
    image: ${KIND_NODE_IMAGE}
  - role: worker
    image: ${KIND_NODE_IMAGE}
```
Note: kind nodes already expose `/var/log/pods` + `/var/log/containers`, so a future
OTel DaemonSet can hostPath-mount them with no extra cluster config.

### `scripts/create-cluster.sh` (sketch)
- `set -euo pipefail`; load `.env` (`set -a; . ./.env; set +a`).
- Run `scripts/preflight.sh`.
- Render: `envsubst < kind/cluster-config.yaml > kind/.cluster-config.rendered.yaml`.
- Idempotent create: skip if `kind get clusters | grep -qx "$CLUSTER_NAME"`,
  else `kind create cluster --config kind/.cluster-config.rendered.yaml`.
- `kubectl wait --for=condition=Ready nodes --all --timeout=120s` then print `kubectl get nodes -o wide`.

### `scripts/preflight.sh` (sketch)
- `docker info` succeeds, else error: "Start Docker Desktop and retry."
- `command -v kind` else `brew install kind`; same for `helm` and `gettext` (provides `envsubst`).

### `Makefile` targets
- `up` → `scripts/create-cluster.sh`
- `down` → `scripts/delete-cluster.sh`
- `recreate` → `down` then `up`
- `status` → `kubectl get nodes,pods -A`
- `kubeconfig` → print `export KUBECONFIG=$(PWD)/.kube/config`

### `.gitignore`
```
.env
.kube/
kind/.cluster-config.rendered.yaml
```

## Execution Steps (after approval)
1. `git init` the project (currently not a repo).
2. Write all files above; `chmod +x scripts/*.sh`.
3. Copy `cp .env.example .env`.
4. Ensure Docker Desktop is running (`open -a Docker`, wait for `docker info`).
5. `brew install kind` (+ `helm`, `gettext` if missing) — via preflight.
6. `make up` → creates the 3-node cluster.

## Verification
- `docker info` returns server details (Docker Desktop up).
- `kind get clusters` lists `clickstack-local`.
- `KUBECONFIG=./.kube/config kubectl get nodes -o wide` → **3 nodes Ready**
  (1 control-plane, 2 workers) on the pinned v1.36.1 image.
- `kubectl get pods -A` → CoreDNS, kube-proxy, kindnet, etc. all `Running`.
- `kubectl cluster-info` → control plane + CoreDNS reachable.
- **Reproducibility check:** `make recreate` tears down and rebuilds cleanly to the
  same 3-node Ready state.

## Out of Scope (next steps in the broader project)
Installing the OpenTelemetry collector (DaemonSet for logs, kubeletstats + k8s-cluster
receivers for metrics), wiring the ClickHouse Cloud exporter, and the ClickStack/HyperDX UI.
