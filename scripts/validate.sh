#!/usr/bin/env bash
# Validate that the stack is up and healthy:
#   1. every pod in the namespace is Ready
#   2. each helm release is deployed
#   3. Grafana reports each provisioned datasource as healthy
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

# alloy (default) or prometheus - see the Makefile and docs/metrics-modes.md.
# Only Karma and Prometheus itself differ between the two: Karma isn't deployed,
# and Prometheus's own server doesn't run, under METRICS_MODE=alloy.
METRICS_MODE="${METRICS_MODE:-alloy}"

# grafana (default) or perses - see the Makefile and docs/dashboard-backends.md.
DASHBOARD_BACKEND="${DASHBOARD_BACKEND:-grafana}"

info "Waiting for all pods in '$NAMESPACE' to become Ready (timeout 5m)..."
# Exclude Succeeded pods (e.g. the mimir make-minio-buckets Job) - a completed
# pod never reports Ready, which would otherwise hang the wait until timeout.
if kubectl wait --for=condition=Ready pods --all \
     --field-selector=status.phase!=Succeeded -n "$NAMESPACE" --timeout=5m; then
  pass "all pods Ready"
else
  fail "some pods did not become Ready"
  kubectl get pods -n "$NAMESPACE"
  FAILS=$((FAILS+1))
fi

info "Checking helm releases are deployed..."
releases=(kube-prometheus-stack metrics-server mimir loki tempo pyroscope alloy headlamp)
if [[ "$DASHBOARD_BACKEND" == "perses" ]]; then
  releases+=(perses perses-operator)
else
  releases+=(grafana ollama)
fi
[[ "$METRICS_MODE" == "prometheus" ]] && releases+=(karma)
for r in "${releases[@]}"; do
  status="$(helm status "$r" -n "$NAMESPACE" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1)"
  if [[ "$status" == *deployed* ]]; then pass "release $r deployed"; else warn "release $r not deployed ($status)"; fi
done

info "Checking metrics-server is serving the metrics.k8s.io API..."
if kubectl top nodes >/dev/null 2>&1; then
  pass "metrics-server API healthy (kubectl top nodes)"
else
  fail "metrics-server API not responding to kubectl top nodes"
  FAILS=$((FAILS+1))
fi

info "Checking $([ "$DASHBOARD_BACKEND" == "perses" ] && echo Perses || echo Grafana) datasource health..."
grafana_datasource_health() {
  local creds="admin:admin"
  # List datasources as "uid<TAB>type" pairs, then health-check each. We need
  # the type because not every datasource plugin ships a backend: frontend-only
  # plugins (e.g. the Alertmanager datasource) can't answer the backend
  # /health endpoint and return "plugin.unavailable" there even when they work
  # fine - the UI "Test" button probes them a different way (see below).
  local pairs
  pairs="$(curl -s -u "$creds" "localhost:${PF_PORT}/api/datasources" \
    | python3 -c 'import json,sys
for d in json.load(sys.stdin):
    print(d["uid"], d.get("type",""), sep="\t")' 2>/dev/null)"
  if [[ -z "$pairs" ]]; then fail "no datasources returned by Grafana"; return 1; fi
  local rc=0 uid type
  while IFS=$'\t' read -r uid type; do
    [[ -z "$uid" ]] && continue
    local out
    out="$(curl -s -u "$creds" "localhost:${PF_PORT}/api/datasources/uid/${uid}/health")"
    if echo "$out" | grep -q '"status":"OK"'; then
      pass "datasource $uid healthy"
    elif echo "$out" | grep -qi 'plugin.unavailable\|plugin unavailable'; then
      # Frontend-only plugin: the backend /health endpoint doesn't exist.
      # Probe it the way Grafana's UI does - proxy a request through to the
      # backing service and treat a 2xx as healthy.
      local probe_path
      case "$type" in
        alertmanager) probe_path="api/v2/status" ;;
        *)            probe_path="" ;;
      esac
      if [[ -z "$probe_path" ]]; then
        warn "datasource $uid ($type) has no backend health check - skipping"
        continue
      fi
      local code
      code="$(curl -s -o /dev/null -w '%{http_code}' -u "$creds" \
        "localhost:${PF_PORT}/api/datasources/proxy/uid/${uid}/${probe_path}")"
      if [[ "$code" =~ ^2 ]]; then
        pass "datasource $uid healthy (frontend plugin, proxied $probe_path -> $code)"
      else
        fail "datasource $uid ($type) unhealthy: proxy $probe_path -> HTTP $code"
        rc=1
      fi
    else
      fail "datasource $uid unhealthy: $out"
      rc=1
    fi
  done <<< "$pairs"
  return $rc
}

# Perses has no Grafana-style per-datasource /health probe, so this checks
# wiring/presence instead of a live backend ping: the four PersesGlobalDatasources
# are visible via the API, and at least one vendored community-mixins dashboard
# loaded into the "observability" project (see helm/perses/templates/dashboards/
# and scripts/vendor-perses-dashboards.py - the Kubernetes namespace name maps
# 1:1 to a Perses project, auto-created by the operator).
#
# Fills the caller's PERSES_NAMES/PERSES_DASHBOARD_COUNT vars; returns success
# only once both are non-empty. Called via with_port_forward, so PF_PORT is set.
perses_state_fetch() {
  PERSES_NAMES="$(curl -s --max-time 5 "localhost:${PF_PORT}/api/v1/globaldatasources" \
    | python3 -c 'import json,sys
for d in json.load(sys.stdin):
    print(d["metadata"]["name"])' 2>/dev/null)"
  PERSES_DASHBOARD_COUNT="$(curl -s --max-time 5 "localhost:${PF_PORT}/api/v1/projects/${NAMESPACE}/dashboards" \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)"
  [[ -n "$PERSES_NAMES" && "${PERSES_DASHBOARD_COUNT:-0}" -gt 0 ]]
}

perses_datasource_health() {
  local names="$PERSES_NAMES" dashboard_count="$PERSES_DASHBOARD_COUNT"
  if [[ -z "$names" ]]; then fail "no global datasources returned by Perses"; return 1; fi
  local rc=0
  for want in prometheus-datasource loki-datasource tempo-datasource pyroscope-datasource; do
    if grep -qx "$want" <<< "$names"; then
      pass "datasource $want present"
    else
      fail "datasource $want missing from Perses"
      rc=1
    fi
  done

  if [[ "${dashboard_count:-0}" -gt 0 ]]; then
    pass "$dashboard_count dashboard(s) loaded into the '$NAMESPACE' project"
  else
    fail "no dashboards found in the '$NAMESPACE' Perses project"
    rc=1
  fi
  return $rc
}

if [[ "$DASHBOARD_BACKEND" == "perses" ]]; then
  # The Operator syncs PersesGlobalDatasource/PersesDashboard CRs into the
  # Perses server asynchronously - triggered by a watch on the Perses CR's
  # own Available condition, not exposed as a condition on the datasource/
  # dashboard CRs themselves, so there's nothing to `kubectl wait` on for
  # "sync complete" the way the Grafana target waits for
  # DatasourceSynchronized. By the time this runs the sync is usually done,
  # but can lag a few seconds, so poll instead of a single check - and
  # re-establish the port-forward tunnel on every attempt rather than trusting
  # one to survive the whole poll window (some networks kill long-idle local
  # port-forwards, which would otherwise look identical to Perses never syncing).
  info "Waiting for Perses datasources/dashboards to sync..."
  PERSES_NAMES=""; PERSES_DASHBOARD_COUNT=""
  attempt=0
  until with_port_forward svc/perses-nodeport 8080 -- perses_state_fetch; do
    attempt=$((attempt+1))
    [[ "$attempt" -ge 40 ]] && break
    sleep 3
  done
  # perses_datasource_health only reads PERSES_NAMES/PERSES_DASHBOARD_COUNT
  # (set by the polling loop above) - no more network calls, so no need to
  # wrap it in another with_port_forward.
  if ! perses_datasource_health; then
    FAILS=$((FAILS+1))
  fi
else
  if ! with_port_forward svc/grafana-service 3000 -- grafana_datasource_health; then
    FAILS=$((FAILS+1))
  fi
fi

info "Checking the NodePort-exposed UIs are reachable on the host..."
if [[ "$DASHBOARD_BACKEND" == "perses" ]]; then
  uis=("perses:8082" "alloy:12345" "alertmanager:9093" "headlamp:4466")
else
  uis=("grafana:3000" "alloy:12345" "alertmanager:9093" "headlamp:4466")
fi
if [[ "$METRICS_MODE" == "prometheus" ]]; then
  uis+=("prometheus:9090" "karma:8081")
fi
for entry in "${uis[@]}"; do
  svc="${entry%%:*}"; port="${entry##*:}"
  if curl -s -o /dev/null --max-time 5 "http://localhost:${port}"; then
    pass "$svc UI reachable at http://localhost:${port}"
  else
    warn "$svc UI not reachable at http://localhost:${port} (kind extraPortMappings need a cluster created from kind/cluster.yaml)"
  fi
done

echo
if [[ "$FAILS" -eq 0 ]]; then
  pass "validation passed"
  exit 0
else
  fail "validation found $FAILS problem(s)"
  exit 1
fi
