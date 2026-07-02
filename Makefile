# =============================================================================
#  Observability demo on kind
#
#  Quick start:   make up          # cluster + full stack + Alloy + validate + demo app
#                 make down        # tear the cluster down
#
#  Run `make help` for the full list of targets.
# =============================================================================

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# ---- Configuration -----------------------------------------------------------
CLUSTER_NAME ?= observability-demo
NAMESPACE    ?= observability
KIND_CONFIG  := kind/cluster.yaml
HELM_DIR     := helm
HELM_TIMEOUT ?= 10m

# ---- Demo application (apps/otel-demo) ----------------------------------------
# An OTel-instrumented Go microservices app that feeds the stack's own
# collectors (Alloy for traces/logs/profiles, Prometheus for metrics). It lives
# in its own namespace and is built into local images loaded straight into kind.
DEMO_NAMESPACE ?= otel-demo
DEMO_DIR       := apps/otel-demo
DEMO_SERVICES  := frontend checkout payment catalog loadgen
DEMO_TAG       ?= dev

# The frontend ships an interactive web UI for generating telemetry by hand.
# The loadgen is an *optional* traffic driver: set DEMO_LOADGEN=false to deploy
# the app without it and drive traffic yourself from the UI at :8080.
DEMO_LOADGEN   ?= true

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
KPS_VERSION       := 87.5.1
HEADLAMP_VERSION  := 0.43.0

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
	@helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null
	@helm repo update grafana grafana-community prometheus-community headlamp >/dev/null
	@echo "Helm repos up to date."

.PHONY: namespace
namespace: ## Ensure the target namespace exists
	@kubectl get namespace $(NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(NAMESPACE)

# ---- Individual component deploys --------------------------------------------
.PHONY: kube-prometheus-stack mimir loki tempo pyroscope grafana alloy headlamp

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

headlamp: repos namespace ## Deploy Headlamp (cluster web UI)
	$(call helm_install,headlamp,headlamp/headlamp,$(HEADLAMP_VERSION))

# ---- Grouped deploys ---------------------------------------------------------
.PHONY: backends stack
backends: mimir loki tempo pyroscope ## Deploy the four LGTM backends
# kube-prometheus-stack goes first: it installs the Prometheus-operator CRDs
# (ServiceMonitor, ...) that every other chart's values now reference.
stack: kube-prometheus-stack backends grafana headlamp ## Deploy Prometheus stack + backends + Grafana + Headlamp

.PHONY: up
up: cluster stack alloy validate demo ## Full setup: cluster + stack + Alloy + validate + demo app
	@echo
	@echo "Done. Grafana http://localhost:3000 (admin/admin) · Alloy http://localhost:12345 · Prometheus http://localhost:9090 · Alertmanager http://localhost:9093 · Headlamp http://localhost:4466 · Demo UI http://localhost:8080."

# ---- Validation & tests ------------------------------------------------------
.PHONY: status
status: ## Show pods and helm releases in the namespace
	@echo "== helm releases =="; helm list -n $(NAMESPACE)
	@echo; echo "== pods =="; kubectl get pods -n $(NAMESPACE) -o wide

.PHONY: validate
validate: ## Check that all workloads are ready and datasources are healthy
	@NAMESPACE=$(NAMESPACE) ./scripts/validate.sh

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

.PHONY: headlamp-ui
headlamp-ui: ## Show the Headlamp UI URL
	@echo "Headlamp at http://localhost:4466 (opens straight in — no token required)."

.PHONY: demo-ui
demo-ui: ## Show the demo app's web UI URL (or port-forward on older clusters)
	@echo "otel-demo web UI at http://localhost:8080."
	@echo "If the page doesn't load, this cluster predates the :8080 port mapping;"
	@echo "recreate it with 'make down && make up', or run:"
	@echo "  kubectl port-forward -n $(DEMO_NAMESPACE) svc/frontend 8080:8080"

.PHONY: logs-alloy
logs-alloy: ## Tail Alloy logs
	@kubectl logs -n $(NAMESPACE) -l app.kubernetes.io/name=alloy -f --max-log-requests 10

# ---- Teardown ----------------------------------------------------------------
.PHONY: clean
clean: ## Uninstall all helm releases (keep the cluster)
	-@for r in headlamp alloy grafana pyroscope tempo loki mimir kube-prometheus-stack; do \
		helm uninstall $$r -n $(NAMESPACE) 2>/dev/null || true; \
	done
	@echo "Releases removed. (Prometheus-operator CRDs are left in place; kind delete removes them.)"

.PHONY: down
down: ## Delete the kind cluster
	@kind delete cluster --name $(CLUSTER_NAME)

# ---- Demo application --------------------------------------------------------
.PHONY: demo-build demo-load demo-deploy demo demo-test demo-clean

demo-build: ## Build the otel-demo service images with podman
	@for svc in $(DEMO_SERVICES); do \
		echo ">> building otel-demo/$$svc:$(DEMO_TAG)"; \
		podman build --build-arg SERVICE=$$svc \
			-t otel-demo/$$svc:$(DEMO_TAG) $(DEMO_DIR) || exit 1; \
	done

demo-load: ## Load the otel-demo images into the kind cluster
	@for svc in $(DEMO_SERVICES); do \
		img=otel-demo/$$svc:$(DEMO_TAG); \
		echo ">> loading $$img into kind"; \
		if ! kind load docker-image $$img --name $(CLUSTER_NAME) 2>/dev/null; then \
			echo ">> docker-image load failed, falling back to image-archive"; \
			tar=$$(mktemp --suffix=.tar); \
			podman save $$img -o $$tar && \
			kind load image-archive $$tar --name $(CLUSTER_NAME) && rm -f $$tar; \
		fi; \
	done

demo-deploy: ## Deploy the otel-demo app (set DEMO_LOADGEN=false to skip the loadgen)
	@kubectl apply -f $(DEMO_DIR)/k8s/namespace.yaml
	@kubectl apply -f $(DEMO_DIR)/k8s/            # core services (non-recursive: skips optional/)
	@if [ "$(DEMO_LOADGEN)" = "true" ]; then \
		echo ">> loadgen: enabled (DEMO_LOADGEN=true)"; \
		kubectl apply -f $(DEMO_DIR)/k8s/optional/loadgen.yaml; \
	else \
		echo ">> loadgen: disabled (DEMO_LOADGEN=$(DEMO_LOADGEN)) — drive traffic from the web UI at :8080"; \
		kubectl delete -f $(DEMO_DIR)/k8s/optional/loadgen.yaml --ignore-not-found; \
	fi
	@echo ">> waiting for otel-demo deployments to become Available..."
	@# Wait on Deployments (not `pods --all`): a just-disabled loadgen leaves a
	@# terminating pod that `pods --all` would block on until timeout.
	@kubectl wait --for=condition=Available deploy --all -n $(DEMO_NAMESPACE) --timeout=3m

demo: demo-build demo-load demo-deploy ## Build + load + deploy the demo app
	@echo
	@echo "Demo app deployed to the '$(DEMO_NAMESPACE)' namespace."
	@echo "  Web UI   : http://localhost:8080  (place orders / drive load by hand)"
	@echo "  loadgen  : $(if $(filter true,$(DEMO_LOADGEN)),on,off)  (toggle with DEMO_LOADGEN=false)"
	@echo "Explore it in Grafana:"
	@echo "  Tempo    : search service.name=frontend"
	@echo "  Loki     : {namespace=\"$(DEMO_NAMESPACE)\"}  (click trace_id -> Tempo)"
	@echo "  Mimir    : demo_orders_total / http_server_request_duration_seconds_count"
	@echo "  Pyroscope: process_cpu for service payment"

demo-test: ## Verify the demo app emits all four signals into the stack
	@NAMESPACE=$(NAMESPACE) DEMO_NAMESPACE=$(DEMO_NAMESPACE) ./scripts/demo-test.sh

demo-clean: ## Remove the demo app (delete its namespace)
	@kubectl delete namespace $(DEMO_NAMESPACE) --ignore-not-found
