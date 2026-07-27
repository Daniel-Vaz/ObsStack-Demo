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

# ---- Exemplars: metrics carry a trace_id (metrics -> traces) ------------------
# Three independent things have to hold for this to pass, and each fails
# silently on its own: the app must serve OpenMetrics (plain text can't carry
# exemplars), Mimir must have exemplar storage enabled
# (max_global_exemplars_per_user > 0, else they're accepted and dropped), and
# Alloy must forward them (send_exemplars, on by default). See
# docs/correlation.md.
info "Exemplars: checking Mimir stored trace_id exemplars on the app's histogram..."
mimir_has_exemplars() {
  local out
  out="$(curl -s --get "localhost:${PF_PORT}/prometheus/api/v1/query_exemplars" \
        --data-urlencode 'query=http_server_request_duration_seconds_bucket' \
        --data-urlencode "start=$(( $(date +%s) - 900 ))" \
        --data-urlencode "end=$(date +%s)")"
  echo "$out" | grep -q '"status":"success"' && echo "$out" | grep -q '"trace_id"'
}
check "Mimir has trace_id exemplars (metrics link to traces)" \
  with_port_forward svc/mimir-gateway 80 -- mimir_has_exemplars

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
# Asserting the *label value* (not just "some profile arrived") is deliberate:
# service_name=payment is the join key the Tempo datasource's tracesToProfiles
# remaps span.service.name onto, so this doubles as a check that trace->profile
# correlation can resolve. See docs/correlation.md.
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

# ---- Span profiles: profiles carry span ids (traces -> profiles, per span) ----
# span_id is deliberately *not* a Pyroscope series label (it would explode
# cardinality), so it can't be checked with LabelValues like service_name above.
# Pyroscope keeps it as a per-sample label and exposes it through a dedicated
# span-selector query - which is exactly what Grafana's embedded flame graph
# calls. Querying with an empty selector returns everything; querying a
# nonsense span id returns an empty flame graph. If the two differ, the span
# index was built, which means otel-profiling-go's pprof labels survived the
# scrape into Pyroscope. See docs/correlation.md.
info "Span profiles: checking Pyroscope built a span index for payment..."
pyroscope_has_span_index() {
  local args start end all none
  start="$(( ($(date +%s) - 900) * 1000 ))"
  end="$(( $(date +%s) * 1000 ))"
  args='"profileTypeID":"process_cpu:cpu:nanoseconds:cpu:nanoseconds","labelSelector":"{service_name=\"payment\"}","start":'"$start"',"end":'"$end"
  span_query() {
    curl -s -X POST "localhost:${PF_PORT}/querier.v1.QuerierService/SelectMergeSpanProfile" \
      -H 'Content-Type: application/json' -d "{$args,\"spanSelector\":[$1]}" | wc -c
  }
  all="$(span_query '')"
  none="$(span_query '"ffffffffffffffff"')"
  [ "$all" -gt "$none" ]
}
check "Pyroscope answers span-profile queries for payment" \
  with_port_forward svc/pyroscope 4040 -- pyroscope_has_span_index

echo
if [[ "$FAILS" -eq 0 ]]; then
  pass "demo app is emitting all four signals into the stack"
  exit 0
else
  fail "demo test found $FAILS problem(s)"
  exit 1
fi
