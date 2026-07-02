#!/usr/bin/env bash
# End-to-end check that the otel-demo app emits all four signals into the stack:
#   metrics  -> Prometheus (PodMonitor) -> Mimir
#   traces   -> Alloy (OTLP) -> Tempo
#   logs     -> Alloy (stdout tail) -> Loki   (with a correlatable trace_id)
#   profiles -> Alloy (pprof scrape) -> Pyroscope
#
# Stack services live in $NAMESPACE (observability); the app lives in
# $DEMO_NAMESPACE (otel-demo). with_port_forward reads $NAMESPACE, so calls that
# target the app prefix NAMESPACE="$DEMO_NAMESPACE" for that one command.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

DEMO_NAMESPACE="${DEMO_NAMESPACE:-otel-demo}"

# ---- App health --------------------------------------------------------------
info "App: waiting for all pods in '$DEMO_NAMESPACE' to be Ready..."
check "all $DEMO_NAMESPACE pods Ready" \
  kubectl wait --for=condition=Ready pods --all -n "$DEMO_NAMESPACE" --timeout=120s

info "App: frontend serves the web UI..."
frontend_ok() { curl -s -o /dev/null -w '%{http_code}' "localhost:${PF_PORT}/" | grep -q '^200'; }
NAMESPACE="$DEMO_NAMESPACE" check "frontend returns 200" \
  with_port_forward svc/frontend 8080 -- frontend_ok

# Drive a burst of orders ourselves so all four signals have fresh data even
# when the loadgen is disabled (DEMO_LOADGEN=false). Each /order fans out to
# checkout -> payment and catalog, producing traces, metrics, logs and CPU.
info "App: driving 30 orders through the frontend..."
drive_orders() { for _ in $(seq 30); do curl -s -o /dev/null "localhost:${PF_PORT}/order"; done; }
NAMESPACE="$DEMO_NAMESPACE" check "frontend places orders" \
  with_port_forward svc/frontend 8080 -- drive_orders

# Give the pipelines a moment: scrape interval + remote_write + trace/profile flush.
info "Giving the pipelines ~20s to ingest..."
sleep 20

# ---- Metrics: app series reached Mimir ---------------------------------------
info "Metrics: querying Mimir for the app's series..."
mimir_has_app_metric() {
  local out
  out="$(curl -s --get "localhost:${PF_PORT}/prometheus/api/v1/query" \
        --data-urlencode 'query=count(http_server_request_duration_seconds_count)')"
  echo "$out" | grep -q '"status":"success"' && \
    echo "$out" | grep -qE '"value":\[[0-9.]+,"[1-9][0-9]*"\]'
}
check "Mimir has app HTTP metrics (remote-written from Prometheus)" \
  with_port_forward svc/mimir-gateway 80 -- mimir_has_app_metric

# ---- Traces: frontend traces reached Tempo -----------------------------------
info "Traces: searching Tempo for service.name=frontend..."
tempo_has_frontend() {
  local out
  out="$(curl -s "localhost:${PF_PORT}/api/search?tags=service.name%3Dfrontend&limit=5")"
  echo "$out" | grep -q '"trace_id"' || echo "$out" | grep -q '"traces"'
}
check "Tempo returns frontend traces" \
  with_port_forward svc/tempo 3200 -- tempo_has_frontend

# ---- Logs: correlatable app logs reached Loki --------------------------------
info "Logs: querying Loki for $DEMO_NAMESPACE streams carrying a trace_id..."
loki_has_app_logs() {
  local out end start
  end="$(date +%s)000000000"
  start="$(( $(date +%s) - 900 ))000000000"
  out="$(curl -s --get "localhost:${PF_PORT}/loki/api/v1/query_range" \
        --data-urlencode 'query={namespace="'"$DEMO_NAMESPACE"'"} |= "trace_id"' \
        --data-urlencode "start=$start" \
        --data-urlencode "end=$end" \
        --data-urlencode 'limit=5')"
  echo "$out" | grep -q '"status":"success"' && echo "$out" | grep -q 'trace_id'
}
check "Loki returns app logs containing a trace_id" \
  with_port_forward svc/loki 3100 -- loki_has_app_logs

# ---- Profiles: payment profiles reached Pyroscope ----------------------------
info "Profiles: checking Pyroscope has a service_name=payment label value..."
pyroscope_has_payment() {
  local out start end
  start="$(( ($(date +%s) - 900) * 1000 ))"
  end="$(( $(date +%s) * 1000 ))"
  out="$(curl -s -X POST "localhost:${PF_PORT}/querier.v1.QuerierService/LabelValues" \
        -H 'Content-Type: application/json' \
        -d '{"name":"service_name","start":'"$start"',"end":'"$end"'}')"
  echo "$out" | grep -q 'payment'
}
check "Pyroscope has profiles for service payment" \
  with_port_forward svc/pyroscope 4040 -- pyroscope_has_payment

echo
if [[ "$FAILS" -eq 0 ]]; then
  pass "demo app is emitting all four signals into the stack"
  exit 0
else
  fail "demo test found $FAILS problem(s)"
  exit 1
fi
