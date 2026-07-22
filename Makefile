.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

.PHONY: help up down recreate pause resume status kubeconfig otel-up otel-down otel-status otel-scenarios hyperdx-sources ingress-up ingress-down ingress-status

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Create the local kind cluster (idempotent)
	@scripts/create-cluster.sh

down: ## Delete the local kind cluster
	@scripts/delete-cluster.sh

recreate: down up ## Tear down and rebuild the cluster from scratch

pause: ## Pause the cluster (stop node containers; state preserved). Resume with make resume
	@scripts/pause-cluster.sh

resume: ## Resume a paused cluster (start node containers, wait for Ready)
	@scripts/resume-cluster.sh

status: ## Show nodes and all pods
	@kubectl get nodes -o wide && echo && kubectl get pods -A

kubeconfig: ## Print the export line to point kubectl at this cluster
	@echo "export KUBECONFIG=$(CURDIR)/.kube/config"

otel-up: ## Deploy the OTel pipeline; SCENARIOS="flag=variant ..."|none picks failures (default: 3 scenarios)
	@SCENARIOS="$(SCENARIOS)" scripts/deploy-otel.sh

otel-down: ## Remove the OTel pipeline (keeps the cluster)
	@scripts/teardown-otel.sh

otel-status: ## Show OTel/demo workloads
	@kubectl -n observability get pods -o wide && echo && kubectl -n otel-demo get pods

otel-scenarios: ## List available failure-scenario flags + variants for SCENARIOS
	@scripts/list-scenarios.sh

hyperdx-sources: ## Configure/print the HyperDX Logs/Traces/Metrics/Sessions sources (pass --apply to attempt via API)
	@scripts/configure-hyperdx-sources.sh $(if $(APPLY),--apply,)

ingress-up: ## Expose the OTel Demo UI on http://localhost:8080 (run after otel-up)
	@scripts/deploy-ingress.sh

ingress-down: ## Remove the ingress controller + demo Ingress (keeps the cluster)
	@scripts/teardown-ingress.sh

ingress-status: ## Show the ingress controller + demo Ingress
	@kubectl -n ingress-nginx get pods -o wide && echo && kubectl -n otel-demo get ingress
