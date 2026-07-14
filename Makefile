.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

.PHONY: help up down recreate status kubeconfig otel-up otel-down otel-status ingress-up ingress-down ingress-status

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Create the local kind cluster (idempotent)
	@scripts/create-cluster.sh

down: ## Delete the local kind cluster
	@scripts/delete-cluster.sh

recreate: down up ## Tear down and rebuild the cluster from scratch

status: ## Show nodes and all pods
	@kubectl get nodes -o wide && echo && kubectl get pods -A

kubeconfig: ## Print the export line to point kubectl at this cluster
	@echo "export KUBECONFIG=$(CURDIR)/.kube/config"

otel-up: ## Deploy the OTel → ClickStack pipeline (gateway, agents, demo)
	@scripts/deploy-otel.sh

otel-down: ## Remove the OTel pipeline (keeps the cluster)
	@scripts/teardown-otel.sh

otel-status: ## Show OTel/demo workloads
	@kubectl -n observability get pods -o wide && echo && kubectl -n otel-demo get pods

ingress-up: ## Expose the OTel Demo UI on http://localhost:8080 (run after otel-up)
	@scripts/deploy-ingress.sh

ingress-down: ## Remove the ingress controller + demo Ingress (keeps the cluster)
	@scripts/teardown-ingress.sh

ingress-status: ## Show the ingress controller + demo Ingress
	@kubectl -n ingress-nginx get pods -o wide && echo && kubectl -n otel-demo get ingress
