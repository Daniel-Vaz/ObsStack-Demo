#!/usr/bin/env bash
# Validate that the stack is up and healthy:
#   1. every pod in the namespace is Ready
#   2. each helm release is deployed
#   3. Grafana reports each provisioned datasource as healthy
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

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
for r in kube-prometheus-stack mimir loki tempo pyroscope grafana alloy; do
  status="$(helm status "$r" -n "$NAMESPACE" -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1)"
  if [[ "$status" == *deployed* ]]; then pass "release $r deployed"; else warn "release $r not deployed ($status)"; fi
done

info "Checking Grafana datasource health..."
grafana_datasource_health() {
  local creds="admin:admin"
  # List datasource UIDs, then hit the health endpoint for each.
  local uids
  uids="$(curl -s -u "$creds" "localhost:${PF_PORT}/api/datasources" | grep -o '"uid":"[^"]*"' | cut -d'"' -f4)"
  if [[ -z "$uids" ]]; then fail "no datasources returned by Grafana"; return 1; fi
  local rc=0
  for uid in $uids; do
    local out
    out="$(curl -s -u "$creds" "localhost:${PF_PORT}/api/datasources/uid/${uid}/health")"
    if echo "$out" | grep -q '"status":"OK"'; then
      pass "datasource $uid healthy"
    else
      fail "datasource $uid unhealthy: $out"
      rc=1
    fi
  done
  return $rc
}
if ! with_port_forward svc/grafana 80 -- grafana_datasource_health; then
  FAILS=$((FAILS+1))
fi

info "Checking the NodePort-exposed UIs are reachable on the host..."
for entry in "grafana:3000" "alloy:12345" "prometheus:9090" "alertmanager:9093"; do
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
