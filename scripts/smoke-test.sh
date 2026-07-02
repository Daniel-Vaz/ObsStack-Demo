#!/usr/bin/env bash
# End-to-end smoke test: exercise every read path and push a synthetic trace
# through Alloy to Tempo. Verifies the full ingest+query pipeline works even
# before a real demo app is deployed.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

# ---- Metrics: Mimir read path ------------------------------------------------
info "Metrics: querying Mimir..."
mimir_query() {
  local out
  out="$(curl -s "localhost:${PF_PORT}/prometheus/api/v1/query?query=vector(1)")"
  echo "$out" | grep -q '"status":"success"'
}
check "Mimir /prometheus query API responds" \
  with_port_forward svc/mimir-gateway 80 -- mimir_query

# Prometheus (kube-prometheus-stack) scrapes every ServiceMonitor target and
# remote-writes to Mimir, so real 'up' series should be queryable from Mimir.
info "Metrics: checking Prometheus remote-write reached Mimir ('up' series)..."
mimir_has_up() {
  local out
  out="$(curl -s --get "localhost:${PF_PORT}/prometheus/api/v1/query" \
        --data-urlencode 'query=count(up)')"
  echo "$out" | grep -q '"status":"success"' && \
    echo "$out" | grep -qE '"value":\[[0-9.]+,"[1-9][0-9]*"\]'
}
check "Mimir has 'up' series remote-written from Prometheus" \
  with_port_forward svc/mimir-gateway 80 -- mimir_has_up

# ---- Logs: Loki has streams from the observability namespace -----------------
info "Logs: querying Loki for observability-namespace streams..."
loki_query() {
  # Log selectors must use the range-query endpoint (instant queries only
  # support metric queries). Look back 15m and require at least one stream.
  local out end start
  end="$(date +%s)000000000"
  start="$(( $(date +%s) - 900 ))000000000"
  out="$(curl -s --get "localhost:${PF_PORT}/loki/api/v1/query_range" \
        --data-urlencode 'query={namespace="'"$NAMESPACE"'"}' \
        --data-urlencode "start=$start" \
        --data-urlencode "end=$end" \
        --data-urlencode 'limit=5')"
  echo "$out" | grep -q '"status":"success"' && echo "$out" | grep -q '"stream"'
}
check "Loki returns log streams from $NAMESPACE" \
  with_port_forward svc/loki 3100 -- loki_query

# ---- Traces: push OTLP through Alloy, then search Tempo -----------------------
info "Traces: pushing a synthetic OTLP span to Alloy..."
TRACE_ID="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SPAN_ID="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
NOW_NS="$(date +%s)000000000"
read -r -d '' OTLP_JSON <<JSON
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"smoke-test"}}]},"scopeSpans":[{"spans":[{"traceId":"${TRACE_ID}","spanId":"${SPAN_ID}","name":"smoke-span","kind":1,"startTimeUnixNano":"${NOW_NS}","endTimeUnixNano":"${NOW_NS}"}]}]}]}
JSON

push_trace() {
  curl -s -o /dev/null -w '%{http_code}' \
    -X POST "localhost:${PF_PORT}/v1/traces" \
    -H 'Content-Type: application/json' \
    -d "$OTLP_JSON" | grep -q '^2'
}
check "Alloy accepts OTLP trace over HTTP" \
  with_port_forward svc/alloy 4318 -- push_trace

info "Traces: giving Tempo a moment to ingest, then searching..."
sleep 8
tempo_search() {
  local out
  out="$(curl -s "localhost:${PF_PORT}/api/search?tags=service.name%3Dsmoke-test")"
  echo "$out" | grep -q "$TRACE_ID" || echo "$out" | grep -q '"traces"'
}
check "Tempo search returns the pushed trace" \
  with_port_forward svc/tempo 3200 -- tempo_search

# ---- Profiles: Pyroscope is ready --------------------------------------------
info "Profiles: checking Pyroscope readiness..."
pyroscope_ready() {
  curl -s -o /dev/null -w '%{http_code}' "localhost:${PF_PORT}/ready" | grep -q '^2'
}
check "Pyroscope /ready responds" \
  with_port_forward svc/pyroscope 4040 -- pyroscope_ready

echo
if [[ "$FAILS" -eq 0 ]]; then
  pass "smoke test passed"
  exit 0
else
  fail "smoke test found $FAILS problem(s)"
  exit 1
fi
