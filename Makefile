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

# ---- Metrics collection mode ---------------------------------------------------
# alloy      (default): Alloy scrapes ServiceMonitors/PodMonitors straight from
#            the Prometheus-Operator CRDs and remote-writes to Mimir; Alloy also
#            syncs PrometheusRules into Mimir's ruler, which evaluates them and
#            fires to the (KPS-deployed) Alertmanager. KPS itself deploys only
#            kube-state-metrics, node-exporter, the Operator, and Alertmanager —
#            no Prometheus server. Karma is not deployed: Grafana Alerting (via
#            the Mimir datasource) covers that role instead.
# prometheus: an opt-in mode for specific testing scenarios — KPS's own
#            Prometheus scrapes and evaluates rules, firing to its Alertmanager,
#            and Karma is deployed as Alertmanager's dashboard. See
#            docs/metrics-modes.md.
# Toggle with: make up METRICS_MODE=prometheus
METRICS_MODE ?= alloy
ifeq ($(filter $(METRICS_MODE),alloy prometheus),)
$(error METRICS_MODE must be 'alloy' or 'prometheus', got '$(METRICS_MODE)')
endif

# Per-chart overlay applied only in METRICS_MODE=prometheus, layered on top of
# each chart's default (alloy-mode) values.yaml.
KPS_EXTRA_VALUES     := $(if $(filter prometheus,$(METRICS_MODE)),--values $(HELM_DIR)/kube-prometheus-stack/values-prometheus-metrics.yaml,)
ALLOY_EXTRA_VALUES   := $(if $(filter prometheus,$(METRICS_MODE)),--values $(HELM_DIR)/alloy/values-prometheus-metrics.yaml,)
MIMIR_EXTRA_VALUES   := $(if $(filter prometheus,$(METRICS_MODE)),--values $(HELM_DIR)/mimir/values-prometheus-metrics.yaml,)
GRAFANA_EXTRA_VALUES := $(if $(filter prometheus,$(METRICS_MODE)),--values $(HELM_DIR)/grafana/values-prometheus-metrics.yaml,)

# ---- Demo application (apps/otel-demo) ----------------------------------------
# An OTel-instrumented Go microservices app that feeds the stack's own
# collectors (Alloy for traces/logs/profiles, and — depending on METRICS_MODE —
# either Alloy or Prometheus for metrics). It lives in its own namespace and is
# built into local images loaded straight into kind.
DEMO_NAMESPACE ?= otel-demo
DEMO_DIR       := apps/otel-demo
DEMO_SERVICES  := frontend checkout payment catalog loadgen
DEMO_TAG       ?= dev

# The frontend ships an interactive web UI for generating telemetry by hand, so
# by default you drive traffic yourself from the UI at :8080. The loadgen is an
# *optional* background traffic driver: set DEMO_LOADGEN=true to also deploy it.
DEMO_LOADGEN   ?= false

# This environment uses Podman rather than Docker; tell kind to use it.
# Exported so every recipe shell (kind create/delete/get) inherits it.
export KIND_EXPERIMENTAL_PROVIDER := podman

# Pinned chart versions (see README for how these were chosen).
# Tempo ships from the grafana-community repo; Grafana is a first-party chart
# (helm/grafana) driven by the Grafana Operator (grafana/grafana-operator, from
# the grafana repo) via CRDs — see docs/architecture.md.
MIMIR_VERSION          := 6.1.0
LOKI_VERSION           := 7.0.0
TEMPO_VERSION          := 2.2.3
PYROSCOPE_VERSION      := 2.1.0
GRAFANA_OPERATOR_VERSION := 5.24.0
ALLOY_VERSION          := 1.10.0
KPS_VERSION            := 87.5.1
HEADLAMP_VERSION       := 0.43.0
OLLAMA_VERSION         := 1.65.0
METRICS_SERVER_VERSION := 3.13.1

# ollama's postStart hook pulls the llama3.2:3b model (~2GB) on first start, and
# Kubernetes doesn't mark the container "Running" (so readiness, and thus
# `helm --wait`) until that hook completes — give it much more room than the
# default HELM_TIMEOUT.
OLLAMA_TIMEOUT ?= 20m

# Common helm install invocation.
# Retries because Helm v4's kstatus waiter aborts on the first transient
# "Failed" status (e.g. StatefulSet pods briefly unschedulable / 503 on a
# cold kind node) instead of polling until --timeout like Helm v3 did.
# The install is idempotent, so a retry succeeds once pods have converged.
# $(5) is an optional per-call timeout override (defaults to $(HELM_TIMEOUT)).
define helm_install
	@for attempt in 1 2 3; do \
		echo ">> $(1): helm upgrade --install (attempt $$attempt)"; \
		helm upgrade --install $(1) $(2) \
			--version $(3) \
			--namespace $(NAMESPACE) --create-namespace \
			--values $(HELM_DIR)/$(1)/values.yaml \
			$(4) \
			--wait --timeout $(if $(5),$(5),$(HELM_TIMEOUT)) && break; \
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
repos: ## Add and update the Grafana + Prometheus + Ollama helm repos
	@helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
	@helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
	@helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null
	@helm repo add ollama-helm https://otwld.github.io/ollama-helm/ >/dev/null
	@helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
	@helm repo update grafana grafana-community prometheus-community headlamp ollama-helm metrics-server >/dev/null
	@echo "Helm repos up to date."

.PHONY: namespace
namespace: ## Ensure the target namespace exists
	@kubectl get namespace $(NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(NAMESPACE)

# ---- Individual component deploys --------------------------------------------
.PHONY: kube-prometheus-stack mimir loki tempo pyroscope grafana-operator grafana alloy headlamp karma ollama metrics-server

kube-prometheus-stack: repos namespace ## Deploy kube-prometheus-stack (Alertmanager, operator, KSM, node-exporter; + Prometheus in METRICS_MODE=prometheus)
	$(call helm_install,kube-prometheus-stack,prometheus-community/kube-prometheus-stack,$(KPS_VERSION),$(KPS_EXTRA_VALUES))

metrics-server: repos namespace ## Deploy metrics-server (kubelet resource metrics for `kubectl top`/HPA; scraped via its built-in ServiceMonitor)
	$(call helm_install,metrics-server,metrics-server/metrics-server,$(METRICS_SERVER_VERSION))

mimir: repos namespace ## Deploy Mimir (metrics)
	$(call helm_install,mimir,grafana/mimir-distributed,$(MIMIR_VERSION),$(MIMIR_EXTRA_VALUES))

loki: repos namespace ## Deploy Loki (logs)
	$(call helm_install,loki,grafana/loki,$(LOKI_VERSION))

tempo: repos namespace ## Deploy Tempo (traces)
	$(call helm_install,tempo,grafana-community/tempo,$(TEMPO_VERSION))

pyroscope: repos namespace ## Deploy Pyroscope (profiles)
	$(call helm_install,pyroscope,grafana/pyroscope,$(PYROSCOPE_VERSION))

grafana-operator: repos namespace ## Deploy the Grafana Operator (reconciles helm/grafana's CRDs into a running Grafana)
	$(call helm_install,grafana-operator,grafana/grafana-operator,$(GRAFANA_OPERATOR_VERSION))

grafana: namespace grafana-operator ## Deploy Grafana (Operator-managed via CRDs; provisioned datasources) from its local chart
	@# First-party local chart (helm/grafana) of CRDs (Grafana, GrafanaDatasource,
	@# ...) — no external repo, so it skips `repos` and
	@# passes a chart path instead of a repo/chart ref. Same retry loop as
	@# helm_install, minus the --version flag (invalid for local paths).
	@for attempt in 1 2 3; do \
		echo ">> grafana: helm upgrade --install (attempt $$attempt)"; \
		helm upgrade --install grafana $(HELM_DIR)/grafana \
			--namespace $(NAMESPACE) --create-namespace \
			--values $(HELM_DIR)/grafana/values.yaml \
			$(GRAFANA_EXTRA_VALUES) \
			--wait --timeout $(HELM_TIMEOUT) && break; \
		if [ $$attempt -eq 3 ]; then \
			echo ">> grafana: still not ready after $$attempt attempts" >&2; exit 1; \
		fi; \
		echo ">> grafana: transient failure, retrying in 15s..."; \
		sleep 15; \
	done
	@# helm --wait only tracks the ConfigMap/RBAC/ServiceMonitor objects this
	@# chart applies directly — it has no notion of the Grafana CR's own
	@# readiness. The actual Grafana Deployment ("grafana-deployment") is
	@# created asynchronously by the Operator's reconcile loop, so wait for it
	@# here explicitly: first for it to exist, then for it to roll out.
	@echo ">> grafana: waiting for the Grafana Operator to create grafana-deployment..."
	@i=0; until kubectl get deployment/grafana-deployment -n $(NAMESPACE) >/dev/null 2>&1; do \
		i=$$((i + 1)); \
		if [ $$i -gt 60 ]; then echo ">> grafana: grafana-deployment was never created by the Operator" >&2; exit 1; fi; \
		sleep 2; \
	done
	@kubectl wait --for=condition=Available deployment/grafana-deployment -n $(NAMESPACE) --timeout=$(HELM_TIMEOUT)
	@# The Grafana pod being Available only means it's serving HTTP — the
	@# Operator still has to separately call Grafana's own API to actually
	@# create the datasources (GrafanaDatasource CRs, reconciled async, same as
	@# the Deployment above). Wait for those too, or `make validate` can race
	@# ahead of an instance that's "up" but not yet provisioned.
	@echo ">> grafana: waiting for datasources to sync into Grafana..."
	@kubectl wait --for=condition=DatasourceSynchronized \
		-l app.kubernetes.io/instance=grafana grafanadatasources.grafana.integreatly.org \
		-n $(NAMESPACE) --timeout=$(HELM_TIMEOUT)

alloy: repos namespace ## Deploy Alloy (telemetry collector; scrapes metrics too in default METRICS_MODE=alloy)
	$(call helm_install,alloy,grafana/alloy,$(ALLOY_VERSION),$(ALLOY_EXTRA_VALUES))

headlamp: repos namespace ## Deploy Headlamp (cluster web UI)
	$(call helm_install,headlamp,headlamp/headlamp,$(HEADLAMP_VERSION))

karma: namespace ## Deploy Karma (Alertmanager alert dashboard) from its local chart
	@# First-party local chart (helm/karma) — no external repo, so it skips
	@# `repos` and passes a chart path instead of a repo/chart ref. Same retry
	@# loop as helm_install, minus the --version flag (invalid for local paths).
	@for attempt in 1 2 3; do \
		echo ">> karma: helm upgrade --install (attempt $$attempt)"; \
		helm upgrade --install karma $(HELM_DIR)/karma \
			--namespace $(NAMESPACE) --create-namespace \
			--values $(HELM_DIR)/karma/values.yaml \
			--wait --timeout $(HELM_TIMEOUT) && break; \
		if [ $$attempt -eq 3 ]; then \
			echo ">> karma: still not ready after $$attempt attempts" >&2; exit 1; \
		fi; \
		echo ">> karma: transient failure, retrying in 15s..."; \
		sleep 15; \
	done

ollama: repos namespace ## Deploy Ollama and pull the llama3.2:3b model (LLM backend for Grafana's Graft AI assistant)
	$(call helm_install,ollama,ollama-helm/ollama,$(OLLAMA_VERSION),,$(OLLAMA_TIMEOUT))

# ---- Grouped deploys ---------------------------------------------------------
.PHONY: backends stack
backends: mimir loki tempo pyroscope ## Deploy the four LGTM backends
# kube-prometheus-stack goes first: it installs the Prometheus-operator CRDs
# (ServiceMonitor, PodMonitor, PrometheusRule, ...) that every other chart's
# values (and Alloy, in METRICS_MODE=alloy) now reference, plus the
# Alertmanager that Karma / Mimir's ruler fires to.
# Karma is only deployed in the METRICS_MODE=prometheus mode — in the default
# alloy mode, Grafana Alerting (via the Mimir datasource) covers that role.
stack: kube-prometheus-stack metrics-server backends grafana headlamp $(if $(filter prometheus,$(METRICS_MODE)),karma,) ## Deploy Prometheus-operator stack + metrics-server + backends + Grafana + Headlamp (+ Karma in METRICS_MODE=prometheus)

.PHONY: up
# Ollama is part of the default flow because Grafana's Graft AI assistant (and
# the grafana-llm-app plugin it builds on — see helm/grafana/values.yaml) use it
# as their local model backend. It's the heaviest thing in the repo (multiple
# CPUs + several GiB of RAM for CPU-only llama3.2:3b inference, ~2GB model pull;
# see helm/ollama/values.yaml), so expect the first `make up` to take a while.
up: cluster stack alloy ollama validate demo ## Full setup: cluster + stack + Alloy + Ollama + validate + demo app
	@echo
	@echo "Done. (METRICS_MODE=$(METRICS_MODE)) Grafana http://localhost:3000 (admin/admin) · Alloy http://localhost:12345 · Alertmanager http://localhost:9093 · Headlamp http://localhost:4466 · Demo UI http://localhost:8080."
	@if [ "$(METRICS_MODE)" = "prometheus" ]; then \
		echo "Prometheus http://localhost:9090 · Karma http://localhost:8081."; \
	else \
		echo "Metrics: Alloy scrapes via Operator CRDs -> Mimir; Mimir's ruler evaluates PrometheusRules -> Alertmanager. View alerts in Grafana Alerting or at the Alertmanager URL above."; \
	fi
	@echo "AI: Grafana ships the Graft assistant (LLM plugin -> Ollama). Open Grafana and find 'Graft' in the nav."

# ---- Validation & tests ------------------------------------------------------
.PHONY: status
status: ## Show pods and helm releases in the namespace
	@echo "== helm releases =="; helm list -n $(NAMESPACE)
	@echo; echo "== pods =="; kubectl get pods -n $(NAMESPACE) -o wide

.PHONY: validate
validate: ## Check that all workloads are ready and datasources are healthy
	@NAMESPACE=$(NAMESPACE) METRICS_MODE=$(METRICS_MODE) ./scripts/validate.sh

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

.PHONY: karma-ui
karma-ui: ## Show the Karma alert dashboard URL
	@echo "Karma at http://localhost:8081 (alert dashboard for Alertmanager)."

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
	-@for r in ollama karma headlamp alloy grafana grafana-operator pyroscope tempo loki mimir metrics-server kube-prometheus-stack; do \
		helm uninstall $$r -n $(NAMESPACE) 2>/dev/null || true; \
	done
	@echo "Releases removed. (Prometheus-operator + Grafana Operator CRDs are left in place; kind delete removes them.)"

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

demo-deploy: ## Deploy the otel-demo app (set DEMO_LOADGEN=true to also deploy the loadgen)
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
	@echo "  loadgen  : $(if $(filter true,$(DEMO_LOADGEN)),on,off)  (toggle with DEMO_LOADGEN=true)"
	@echo "Explore it in Grafana:"
	@echo "  Tempo    : search service.name=frontend"
	@echo "  Loki     : {namespace=\"$(DEMO_NAMESPACE)\"}  (click trace_id -> Tempo)"
	@echo "  Mimir    : demo_orders_total / http_server_request_duration_seconds_count"
	@echo "  Pyroscope: process_cpu for service payment"

demo-test: ## Verify the demo app emits all four signals into the stack
	@NAMESPACE=$(NAMESPACE) DEMO_NAMESPACE=$(DEMO_NAMESPACE) ./scripts/demo-test.sh

demo-clean: ## Remove the demo app (delete its namespace)
	@kubectl delete namespace $(DEMO_NAMESPACE) --ignore-not-found
