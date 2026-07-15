# otel-demo - an OpenTelemetry-instrumented demo app

A small, self-contained microservices app (Go) that generates **all four
signals** - metrics, logs, traces, profiles - and feeds them into **this repo's
existing Grafana LGTM stack**.

Everything runs in its own **`otel-demo`** namespace.

## Topology

```
        (optional)
loadgen ─┐
         ├─▶ frontend ─▶ checkout ─▶ payment   (burns CPU on /pay)
you ─────┘          └──▶ catalog              (variable latency)
 (web UI)
```

The **frontend serves an interactive web UI at `http://localhost:8080`** - click
*Place order*, *Browse catalog*, fire a burst, or flip on *Auto load* to drive a
steady stream from the browser. Each `/order` produces a two-level distributed
trace with fan-out.

The UI also has a **simulated errors** control: set it to e.g. `30%` and a third
of orders will fail on purpose (payment "declines" the charge). The failure is
injected in the `payment` service and propagates back up the call chain, so it
surfaces in **all three signals at once** - an errored span with an exception
event (Tempo), `ERROR` log lines from payment → checkout → frontend (Loki), and
the `demo_order_errors_total` / `demo_payment_failures_total` counters plus 5xx
`http_server_request_duration_seconds_count` (Mimir). See
[Simulated errors & alerting](#simulated-errors--alerting).

![otel-demo traffic console web UI at localhost:8080 - Place order / Browse catalog / Send burst controls, a live request counter, and a response log](../../docs/images/oteldemoapp-ui.png)
*The traffic console at `http://localhost:8080` - drive orders by hand or with *Auto load*, and watch requests, 2xx, and errors tick up live. Every order fans out `frontend → checkout → payment` and `frontend → catalog`.*

`loadgen` is an **optional** background traffic driver that hits `/order` on a
timer so the stack always has live telemetry with no interaction. It's **off by
default** - you generate traffic by hand from the UI; set `DEMO_LOADGEN=true` to
also deploy it.

### Frontend routes

| Route      | What it does |
|------------|--------------|
| `GET /`        | the interactive web UI (embedded `index.html`) |
| `GET /order`   | full order: fans out to catalog + checkout → payment (traced). `?fail_rate=0..1` injects simulated failures |
| `GET /catalog` | catalog-only browse: a shorter trace shape (traced) |

The `fail_rate` query param is forwarded frontend → checkout → payment; the UI's
*simulated errors* percentage sets it. `payment` also honours a `FAIL_RATE` env
var as a baseline for traffic that doesn't carry the param (e.g. the loadgen).

## How each signal reaches the stack (no stack changes required)

| Signal   | How the app emits it | How the stack collects it |
|----------|----------------------|---------------------------|
| Traces   | OTel SDK, OTLP/gRPC to `OTEL_EXPORTER_OTLP_ENDPOINT` (Alloy) | Alloy `otelcol.receiver.otlp` → Tempo |
| Metrics  | OTel SDK + Prometheus exporter on `/metrics` (RED via `otelhttp` + `demo_orders` / `demo_order_errors` / `demo_payment_failures` counters) | `PodMonitor` → Alloy scrape → remote_write → Mimir |
| Logs     | `slog` JSON to stdout, including a **`trace_id`** field | Alloy pod-log tailing → Loki (promoted to structured metadata; Grafana links `trace_id` → Tempo) |
| Profiles | Go `net/http/pprof` on the same port; pod annotated `pyroscope.io/scrape: "true"` | Alloy `pyroscope.scrape` → Pyroscope |

Two details make this work with the stack untouched:

- The log field is spelled **`trace_id`** to match Grafana's Loki `derivedFields`
  regex in `helm/grafana/values.yaml` and the structured-metadata key Alloy promotes.
- Each service serves app routes, `/metrics`, and `/debug/pprof/*` on **one**
  container port, so Alloy's pod discovery resolves exactly one Pyroscope target.

## Simulated errors & alerting

Dial the web UI's **simulated errors** slider above `0%` (or set `FAIL_RATE` on
the payment deployment) and the demo starts failing that fraction of orders,
lighting up every signal - and the two example alerting paths this repo ships:

- **Metric-based - Mimir ruler.** `k8s/prometheusrules.yaml` is a
  `PrometheusRule` that Alloy syncs into **Mimir's ruler**, which evaluates it.
  It alerts on the failed-order ratio (`demo_order_errors_total` /
  `demo_orders_total`), on `demo_payment_failures_total`, and on 5xx
  `http_server_request_duration_seconds_count`.
- **Log-based - Loki ruler.** `k8s/loki-rules.yaml` is a `ConfigMap` of LogQL
  alerting rules synced into the **Loki ruler** by the chart's rules sidecar
  (enabled in `helm/loki/values.yaml`). It alerts on the rate/ratio of `ERROR`
  log lines and on `payment declined` messages.

Both fire into the **same Alertmanager**, so metric and log alerts land together
and show up in **Grafana Alerting** (and the Alertmanager UI at
`http://localhost:9093`). Query the live Loki rules with
`kubectl exec … -- wget -qO- localhost:3100/loki/api/v1/rules`.

## Layout

```
apps/otel-demo/
  cmd/frontend/          # main.go + index.html (embedded web UI, errors slider)
  cmd/{checkout,payment,catalog,loadgen}/main.go
  internal/telemetry/    # one Init() sets up traces + metrics + logging
  internal/httpx/        # OTel mux/client (+ /metrics, /pprof) and fault-injection helpers
  Dockerfile             # multi-stage; --build-arg SERVICE=<name>
  k8s/                   # namespace, deployments/services, PodMonitor, dashboard
  k8s/prometheusrules.yaml  # metric-based alerts on the simulated errors
  k8s/loki-rules.yaml       # log-based alerts (Loki ruler; lives in the observability ns)
  k8s/optional/          # loadgen (applied only when DEMO_LOADGEN=true)
```

## Build & run

From the repo root (the stack must already be up via `make up`):

```bash
make demo                      # build images, load into kind, deploy the app (no loadgen)
make demo DEMO_LOADGEN=true    # same, but also deploy the background loadgen
make demo-ui                   # print the web UI URL (http://localhost:8080)
make demo-test                 # assert all four signals are flowing
make demo-clean                # delete the otel-demo namespace
```

Then open the **web UI at `http://localhost:8080`** to drive traffic, and
explore the signals in Grafana (`http://localhost:3000`, admin/admin) - see the
repo README's "Demo application" section for the guided tour.

> The `:8080` host mapping is published by the kind cluster config. On a cluster
> created before this was added, run `make down && make up`, or reach the UI with
> `kubectl port-forward -n otel-demo svc/frontend 8080:8080`.

## Local development

```bash
cd apps/otel-demo
go build ./...        # compile all services
go vet ./...
```

Rebuild a single image directly with podman:

```bash
podman build --build-arg SERVICE=payment -t otel-demo/payment:dev .
```
