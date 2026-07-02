# =============================================================================
#  Grafana LGTM stack demo on kind
#
#  Quick start:   make up          # cluster + full stack + Alloy + validate
#                 make grafana-ui  # print the Grafana URL (http://localhost:3000)
#                 make down        # tear the cluster down
#
#  Run `make help` for the full list of targets.
# =============================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# ---- Configuration -----------------------------------------------------------
CLUSTER_NAME ?= grafana-lgtm-demo
NAMESPACE    ?= observability
KIND_CONFIG  := kind/cluster.yaml
HELM_DIR     := helm
HELM_TIMEOUT ?= 10m

# This environment uses Podman rather than Docker; tell kind to use it.
# Exported so every recipe shell (kind create/delete/get) inherits it.
export KIND_EXPERIMENTAL_PROVIDER := podman

# Pinned chart versions (see README for how these were chosen).
# Grafana and Tempo now ship from the grafana-community repo; the rest from grafana.
MIMIR_VERSION     := 6.1.0
LOKI_VERSION      := 7.0.0
TEMPO_VERSION     := 2.2.3
PYROSCOPE_VERSION := 2.1.0
GRAFANA_VERSION   := 12.7.2
ALLOY_VERSION     := 1.10.0
KPS_VERSION       := 87.5.1   # prometheus-community/kube-prometheus-stack

# Common helm install invocation.
# Retries because Helm v4's kstatus waiter aborts on the first transient
# "Failed" status (e.g. StatefulSet pods briefly unschedulable / 503 on a
# cold kind node) instead of polling until --timeout like Helm v3 did.
# The install is idempotent, so a retry succeeds once pods have converged.
define helm_install
	@for attempt in 1 2 3; do \
		echo ">> $(1): helm upgrade --install (attempt $$attempt)"; \
		helm upgrade --install $(1) $(2) \
			--version $(3) \
			--namespace $(NAMESPACE) --create-namespace \
			--values $(HELM_DIR)/$(1)/values.yaml \
			--wait --timeout $(HELM_TIMEOUT) && break; \
		if [ $$attempt -eq 3 ]; then \
			echo ">> $(1): still not ready after $$attempt attempts" >&2; exit 1; \
		fi; \
		echo ">> $(1): transient failure, pods still converging — retrying in 15s..."; \
		sleep 15; \
	done
endef

# ---- Help --------------------------------------------------------------------
.PHONY: help
help: ## Show this help
	@echo "Grafana LGTM demo — available targets:"
	@echo
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---- Preflight ---------------------------------------------------------------
.PHONY: check-tools
check-tools: ## Verify required CLIs are installed
	@for bin in podman kind kubectl helm; do \
		command -v $$bin >/dev/null 2>&1 || { echo "ERROR: '$$bin' not found in PATH"; exit 1; }; \
	done
	@echo "All required tools present."

# ---- Cluster lifecycle -------------------------------------------------------
.PHONY: cluster
cluster: check-tools ## Create the kind cluster (no-op if it exists)
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		echo "kind cluster '$(CLUSTER_NAME)' already exists."; \
	else \
		kind create cluster --config $(KIND_CONFIG); \
	fi
	@kubectl cluster-info --context kind-$(CLUSTER_NAME) >/dev/null && echo "Cluster ready."

.PHONY: repos
repos: ## Add and update the Grafana + Prometheus helm repos
	@helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
	@helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
	@helm repo update grafana grafana-community prometheus-community >/dev/null
	@echo "Helm repos up to date."

.PHONY: namespace
namespace: ## Ensure the target namespace exists
	@kubectl get namespace $(NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(NAMESPACE)

# ---- Individual component deploys --------------------------------------------
.PHONY: kube-prometheus-stack mimir loki tempo pyroscope grafana alloy

kube-prometheus-stack: repos namespace ## Deploy kube-prometheus-stack (Prometheus, Alertmanager, operator, KSM, node-exporter)
	$(call helm_install,kube-prometheus-stack,prometheus-community/kube-prometheus-stack,$(KPS_VERSION))

mimir: repos namespace ## Deploy Mimir (metrics)
	$(call helm_install,mimir,grafana/mimir-distributed,$(MIMIR_VERSION))

loki: repos namespace ## Deploy Loki (logs)
	$(call helm_install,loki,grafana/loki,$(LOKI_VERSION))

tempo: repos namespace ## Deploy Tempo (traces)
	$(call helm_install,tempo,grafana-community/tempo,$(TEMPO_VERSION))

pyroscope: repos namespace ## Deploy Pyroscope (profiles)
	$(call helm_install,pyroscope,grafana/pyroscope,$(PYROSCOPE_VERSION))

grafana: repos namespace ## Deploy Grafana (with provisioned datasources)
	$(call helm_install,grafana,grafana-community/grafana,$(GRAFANA_VERSION))

alloy: repos namespace ## Deploy Alloy (telemetry collector)
	$(call helm_install,alloy,grafana/alloy,$(ALLOY_VERSION))

# ---- Grouped deploys ---------------------------------------------------------
.PHONY: backends stack
backends: mimir loki tempo pyroscope ## Deploy the four LGTM backends
# kube-prometheus-stack goes first: it installs the Prometheus-operator CRDs
# (ServiceMonitor, ...) that every other chart's values now reference.
stack: kube-prometheus-stack backends grafana ## Deploy Prometheus stack + backends + Grafana

.PHONY: up
up: cluster stack alloy validate ## Full setup: cluster + stack + Alloy + validate
	@echo
	@echo "Done. Grafana http://localhost:3000 (admin/admin) · Alloy http://localhost:12345 · Prometheus http://localhost:9090 · Alertmanager http://localhost:9093."

# ---- Validation & tests ------------------------------------------------------
.PHONY: status
status: ## Show pods and helm releases in the namespace
	@echo "== helm releases =="; helm list -n $(NAMESPACE)
	@echo; echo "== pods =="; kubectl get pods -n $(NAMESPACE) -o wide

.PHONY: validate
validate: ## Check that all workloads are ready and datasources are healthy
	@NAMESPACE=$(NAMESPACE) ./scripts/validate.sh

.PHONY: smoke-test
smoke-test: ## Push synthetic telemetry through Alloy and query it back
	@NAMESPACE=$(NAMESPACE) ./scripts/smoke-test.sh

# ---- Access helpers ----------------------------------------------------------
.PHONY: grafana-ui
grafana-ui: ## Show the Grafana URL (admin/admin)
	@echo "Grafana at http://localhost:3000 (admin/admin)."

.PHONY: alloy-ui
alloy-ui: ## Show the Alloy UI URL
	@echo "Alloy UI at http://localhost:12345."

.PHONY: prometheus-ui
prometheus-ui: ## Show the Prometheus UI URL
	@echo "Prometheus at http://localhost:9090 (targets: /targets)."

.PHONY: alertmanager-ui
alertmanager-ui: ## Show the Alertmanager UI URL
	@echo "Alertmanager at http://localhost:9093."

.PHONY: logs-alloy
logs-alloy: ## Tail Alloy logs
	@kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=alloy -f --max-log-requests 10

# ---- Teardown ----------------------------------------------------------------
.PHONY: clean
clean: ## Uninstall all helm releases (keep the cluster)
	-@for r in alloy grafana pyroscope tempo loki mimir kube-prometheus-stack; do \
		helm uninstall $$r -n $(NAMESPACE) 2>/dev/null || true; \
	done
	@echo "Releases removed. (Prometheus-operator CRDs are left in place; kind delete removes them.)"

.PHONY: down
down: ## Delete the kind cluster
	@kind delete cluster --name $(CLUSTER_NAME)
