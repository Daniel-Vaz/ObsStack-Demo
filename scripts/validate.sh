#!/usr/bin/env bash
# Validate that the stack is up and healthy:
#   1. every pod in the namespace is Ready
#   2. each helm release is deployed
#   3. Grafana reports each provisioned datasource as healthy
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

# alloy (default) or prometheus (legacy toggle) — see the Makefile. Only
# Karma and Prometheus itself differ between the two: Karma isn't deployed,
# and Prometheus's own server doesn't run, under METRICS_MODE=alloy.
METRICS_MODE="${METRICS_MODE:-alloy}"

info "Waiting for all pods in '$NAMESPACE' to become Ready (timeout 5m)..."
# Exclude Succeeded pods (e.g. the mimir make-minio-buckets Job) — a completed
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
releases=(kube-prometheus-stack mimir loki tempo pyroscope grafana alloy headlamp ollama)
[[ "$METRICS_MODE" == "prometheus" ]] && releases+=(karma)
for r in "${releases[@]}"; do
  status="$(helm status "$r" -n "$NAMESPACE" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1)"
  if [[ "$status" == *deployed* ]]; then pass "release $r deployed"; else warn "release $r not deployed ($status)"; fi
done

info "Checking Grafana datasource health..."
grafana_datasource_health() {
  local creds="admin:admin"
  # List datasources as "uid<TAB>type" pairs, then health-check each. We need
  # the type because not every datasource plugin ships a backend: frontend-only
  # plugins (e.g. the Alertmanager datasource) can't answer the backend
  # /health endpoint and return "plugin.unavailable" there even when they work
  # fine — the UI "Test" button probes them a different way (see below).
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
      # Probe it the way Grafana's UI does — proxy a request through to the
      # backing service and treat a 2xx as healthy.
      local probe_path
      case "$type" in
        alertmanager) probe_path="api/v2/status" ;;
        *)            probe_path="" ;;
      esac
      if [[ -z "$probe_path" ]]; then
        warn "datasource $uid ($type) has no backend health check — skipping"
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
if ! with_port_forward svc/grafana-service 3000 -- grafana_datasource_health; then
  FAILS=$((FAILS+1))
fi

info "Checking the NodePort-exposed UIs are reachable on the host..."
uis=("grafana:3000" "alloy:12345" "alertmanager:9093" "headlamp:4466")
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
