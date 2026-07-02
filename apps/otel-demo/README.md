# otel-demo — an OpenTelemetry-instrumented demo app

A small, self-contained microservices app (Go) that generates **all four
signals** — metrics, logs, traces, profiles — and feeds them into **this repo's
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

The **frontend serves an interactive web UI at `http://localhost:8080`** — click
*Place order*, *Browse catalog*, fire a burst, or flip on *Auto load* to drive a
steady stream from the browser. Each `/order` produces a two-level distributed
trace with fan-out.

`loadgen` is an **optional** background traffic driver that hits `/order` on a
timer so the stack always has live telemetry with no interaction. It's **off by
default** — you generate traffic by hand from the UI; set `DEMO_LOADGEN=true` to
also deploy it.

### Frontend routes

| Route      | What it does |
|------------|--------------|
| `GET /`        | the interactive web UI (embedded `index.html`) |
| `GET /order`   | full order: fans out to catalog + checkout → payment (traced) |
| `GET /catalog` | catalog-only browse: a shorter trace shape (traced) |

## How each signal reaches the stack (no stack changes required)

| Signal   | How the app emits it | How the stack collects it |
|----------|----------------------|---------------------------|
| Traces   | OTel SDK, OTLP/gRPC to `OTEL_EXPORTER_OTLP_ENDPOINT` (Alloy) | Alloy `otelcol.receiver.otlp` → Tempo |
| Metrics  | OTel SDK + Prometheus exporter on `/metrics` (RED via `otelhttp` + a `demo_orders` counter) | `PodMonitor` → kube-prometheus-stack scrape → remote_write → Mimir |
| Logs     | `slog` JSON to stdout, including a **`trace_id`** field | Alloy pod-log tailing → Loki (promoted to structured metadata; Grafana links `trace_id` → Tempo) |
| Profiles | Go `net/http/pprof` on the same port; pod annotated `pyroscope.io/scrape: "true"` | Alloy `pyroscope.scrape` → Pyroscope |

Two details make this work with the stack untouched:

- The log field is spelled **`trace_id`** to match Grafana's Loki `derivedFields`
  regex in `helm/grafana/values.yaml` and the structured-metadata key Alloy promotes.
- Each service serves app routes, `/metrics`, and `/debug/pprof/*` on **one**
  container port, so Alloy's pod discovery resolves exactly one Pyroscope target.

## Layout

```
apps/otel-demo/
  cmd/frontend/          # main.go + index.html (embedded web UI)
  cmd/{checkout,payment,catalog,loadgen}/main.go
  internal/telemetry/    # one Init() sets up traces + metrics + logging
  internal/httpx/        # OTel-instrumented mux (+ /metrics, /pprof) and client
  Dockerfile             # multi-stage; --build-arg SERVICE=<name>
  k8s/                   # namespace, deployments/services, PodMonitor, dashboard
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
explore the signals in Grafana (`http://localhost:3000`, admin/admin) — see the
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
