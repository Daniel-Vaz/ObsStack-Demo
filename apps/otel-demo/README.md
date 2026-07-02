# otel-demo — an OpenTelemetry-instrumented demo app

A small, self-contained microservices app (Go) that generates **all four
signals** — metrics, logs, traces, profiles — and feeds them into **this repo's
existing Grafana LGTM stack** instead of any bundled collectors/backends. It's
the "real workload" counterpart to `make smoke-test`.

Everything runs in its own **`otel-demo`** namespace.

## Topology

```
loadgen ─▶ frontend ─▶ checkout ─▶ payment   (burns CPU on /pay)
                   └──▶ catalog              (variable latency)
```

`loadgen` continuously drives `frontend`, so the stack always has live
telemetry. Each request produces a two-level distributed trace with fan-out.

## How each signal reaches the stack (no stack changes required)

| Signal   | How the app emits it | How the stack collects it |
|----------|----------------------|---------------------------|
| Traces   | OTel SDK, OTLP/gRPC to `OTEL_EXPORTER_OTLP_ENDPOINT` (Alloy) | Alloy `otelcol.receiver.otlp` → Tempo |
| Metrics  | OTel SDK + Prometheus exporter on `/metrics` (RED via `otelhttp` + a `demo_orders` counter) | `PodMonitor` → kube-prometheus-stack scrape → remote_write → Mimir |
| Logs     | `slog` JSON to stdout, including a **`traceID`** field | Alloy pod-log tailing → Loki (Grafana derived field links `traceID` → Tempo) |
| Profiles | Go `net/http/pprof` on the same port; pod annotated `pyroscope.io/scrape: "true"` | Alloy `pyroscope.scrape` → Pyroscope |

Two details make this work with the stack untouched:

- The log field is spelled **`traceID`** (no underscore) to match Grafana's Loki
  `derivedFields` regex in `helm/grafana/values.yaml`.
- Each service serves app routes, `/metrics`, and `/debug/pprof/*` on **one**
  container port, so Alloy's pod discovery resolves exactly one Pyroscope target.

## Layout

```
apps/otel-demo/
  cmd/{frontend,checkout,payment,catalog,loadgen}/main.go
  internal/telemetry/   # one Init() sets up traces + metrics + logging
  internal/httpx/        # OTel-instrumented mux (+ /metrics, /pprof) and client
  Dockerfile             # multi-stage; --build-arg SERVICE=<name>
  k8s/                   # namespace, deployments/services, PodMonitor, dashboard
```

## Build & run

From the repo root (the stack must already be up via `make up`):

```bash
make demo        # build images, load into kind, deploy to the otel-demo namespace
make demo-test   # assert all four signals are flowing
make demo-clean  # delete the otel-demo namespace
```

Then explore in Grafana (`http://localhost:3000`, admin/admin) — see the repo
README's "Demo application" section for the guided tour.

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
