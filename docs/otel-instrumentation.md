# How the demo app is OpenTelemetry-instrumented (a beginner's guide)

This is a gentle, ground-up walkthrough of *how* the [`apps/otel-demo`](../apps/otel-demo/)
services are wired for observability. If you've never added OpenTelemetry (OTel) to a
service before, start here. For the design rationale see
[architecture.md](./architecture.md); for build/run commands see the
[app README](../apps/otel-demo/README.md).

## What "instrumented" even means

A service is **instrumented** when, in addition to doing its job, it *emits telemetry* -
data about what it's doing - that an outside system can collect and show you. This demo
emits the **four signals** of observability:

| Signal | Answers the question | Example from this app |
|--------|----------------------|-----------------------|
| **Traces** | "What happened during this one request, across services?" | `frontend → checkout → payment` as a single timeline |
| **Metrics** | "How much / how fast / how often, aggregated over time?" | request rate, error rate, latency; a `demo_orders` counter |
| **Logs** | "What did the code say happened, line by line?" | `"order placed"`, `"payment authorized"` |
| **Profiles** | "Where is my CPU/memory actually going?" | the hashing hot-loop in `payment` |

**OpenTelemetry (OTel)** is the vendor-neutral standard + libraries for producing this
telemetry. You instrument your code once against OTel, and any compatible backend can
receive it. In this repo the backend is the Grafana **LGTM** stack (Loki, Grafana, Tempo,
Mimir) plus Pyroscope and Alloy.

## The mental model: app → collector → store → Grafana

```
  your Go service                 Grafana Alloy               Grafana
  (emits signals)  ───────────▶   (collects & forwards)   ───────────▶  (you look here)
                                                            Tempo / Loki
                                                            Mimir / Pyroscope
```

The key beginner insight: **the app does not talk to Tempo/Loki/Mimir/Pyroscope
directly.** It hands each signal to a nearby *collector*, which forwards it to the right
store. This keeps the app simple and lets you swap backends without touching code.

## Where the instrumentation lives

Almost all of the OTel wiring is in **two small shared files**, so each service's
`main.go` stays focused on business logic:

- [`internal/telemetry/telemetry.go`](../apps/otel-demo/internal/telemetry/telemetry.go) -
  one `Init()` call that sets up traces, metrics, and logging.
- [`internal/httpx/httpx.go`](../apps/otel-demo/internal/httpx/httpx.go) - an
  OTel-instrumented HTTP server and client, plus the `/metrics` and `/debug/pprof`
  endpoints.

Every service (`frontend`, `checkout`, `payment`, `catalog`, `loadgen`) just calls into
these. Let's walk each signal from the app's side.

## 1. Traces - one `Init()`, then automatic propagation

A **trace** follows a single request as it hops between services. Each hop is a **span**
(a timed operation with a name and attributes). Spans link together via a **trace ID**
that travels along with the request.

### Setup (once per service)

Every service starts the same way - one call wires up everything:

```go
tel, err := telemetry.Init(ctx, "frontend")  // service name
defer tel.Shutdown(context.Background())      // flush the last spans on exit
```

Inside [`Init`](../apps/otel-demo/internal/telemetry/telemetry.go#L49), the trace exporter
is created with **no hard-coded address**:

```go
texp, err := otlptracegrpc.New(ctx)   // reads OTEL_EXPORTER_OTLP_ENDPOINT from the env
```

The endpoint comes from a standard environment variable set in the Kubernetes manifest
([`k8s/frontend.yaml`](../apps/otel-demo/k8s/frontend.yaml#L31)):

```yaml
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: http://alloy.observability.svc.cluster.local:4317   # send traces to Alloy
```

This is a deliberate OTel convention: **configuration by environment variable**, so the
same binary points at any collector without a rebuild. Traces go to Alloy over OTLP/gRPC,
and Alloy forwards them to Tempo.

### Server spans - created for you

You almost never create spans by hand for incoming requests. The
[`httpx.Handle`](../apps/otel-demo/internal/httpx/httpx.go#L47) helper wraps each route in
`otelhttp`, which starts a span automatically:

```go
func Handle(mux *http.ServeMux, pattern, op string, h http.HandlerFunc) {
    mux.Handle(pattern, otelhttp.NewHandler(h, op))  // span named `op` per request
}
```

So `frontend`'s route becomes a span the moment a request arrives - no manual code:

```go
httpx.Handle(mux, "/", "GET /", func(w http.ResponseWriter, r *http.Request) { ... })
```

### Context propagation - how the trace crosses service boundaries

This is the part that surprises newcomers. For `frontend → checkout → payment` to show up
as **one** trace (not three separate ones), the trace ID must ride along on the outgoing
HTTP calls. Two things make that happen:

1. **The instrumented client** in
   [`httpx.Client`](../apps/otel-demo/internal/httpx/httpx.go#L53) injects the W3C
   `traceparent` header automatically:

   ```go
   Transport: otelhttp.NewTransport(http.DefaultTransport)
   ```

2. **Passing `r.Context()` through.** The incoming request's context carries the current
   span. As long as you pass it into the outgoing call, the child request joins the trace:

   ```go
   ctx := r.Context()                                  // has the active span
   cat, err := httpx.Get(ctx, client, catalogURL+"/products")  // ctx flows downstream
   ```

The golden rule for beginners: **always thread `ctx` through your call chain.** That single
variable is how OTel knows one operation is part of another.

### Manual spans - for interesting sub-operations

Sometimes you *do* want a span for a chunk of work inside a service. `payment` marks its
CPU-heavy card authorization so it stands out in the trace waterfall
([`cmd/payment/main.go`](../apps/otel-demo/cmd/payment/main.go#L33)):

```go
_, span := tracer.Start(ctx, "authorize-card")
sum := burnCPU(15000)
span.End()
```

`catalog` does the same around its simulated database query (`"query-inventory"`). These
are the only two hand-written spans in the whole app - everything else is automatic.

## 2. Metrics - the OTel SDK + a `/metrics` endpoint

**Metrics** are numbers aggregated over time. This app produces two kinds:

**Automatic RED metrics.** Because every route is wrapped in `otelhttp` (see above), you get
Rate/Errors/Duration histograms per route for free - no extra code.

**A custom counter.** `frontend` counts completed orders
([`cmd/frontend/main.go`](../apps/otel-demo/cmd/frontend/main.go#L31)):

```go
orders, _ := otel.Meter("frontend").Int64Counter("demo_orders",
    metric.WithDescription("orders placed through the frontend"))
// ...later, per successful order:
orders.Add(ctx, 1, metric.WithAttributes(attribute.String("route", "/")))
```

### How the stack reads them (pull, not push)

Metrics work differently from traces. Instead of the app *pushing* to a collector, the app
**exposes** its current metric values at an HTTP endpoint and the collector **pulls**
(scrapes) them on a schedule. `Init` sets up a Prometheus exporter, and
[`httpx.NewMux`](../apps/otel-demo/internal/httpx/httpx.go#L26) serves it:

```go
mux.Handle("/metrics", promhttp.Handler())   // the collector scrapes this
```

A `PodMonitor` tells the collector which pods to scrape (it selects the `scrape: metrics`
pod label). Alloy reads that `PodMonitor` straight from the Prometheus-Operator CRDs,
scrapes the endpoint, and remote-writes to Mimir. **You expose `/metrics`; the platform
does the rest.**

## 3. Logs - structured JSON, correlated to traces

The app logs with Go's standard `slog`, configured in `Init` to emit **JSON** to stdout
([`telemetry.go`](../apps/otel-demo/internal/telemetry/telemetry.go#L88)):

```go
slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, ...)).With("service", serviceName))
```

Nothing in the app ships logs anywhere - it just writes to stdout. Grafana Alloy tails the
pod's stdout (standard Kubernetes log collection) and pushes it to Loki. This is the
easiest signal to reason about: **print to stdout, the platform collects it.**

### The one clever bit: linking a log line to its trace

When you view a trace in Grafana and want the exact log lines from that request, the log
needs to carry the **trace ID**. The
[`telemetry.Log(ctx)`](../apps/otel-demo/internal/telemetry/telemetry.go#L100) helper pulls
the trace ID out of the context and attaches it to every line:

```go
func Log(ctx context.Context) *slog.Logger {
    l := slog.Default()
    if sc := trace.SpanContextFromContext(ctx); sc.HasTraceID() {
        l = l.With("trace_id", sc.TraceID().String(), "span_id", sc.SpanID().String())
    }
    return l
}
```

So handlers always log via `telemetry.Log(ctx)` rather than the bare logger:

```go
telemetry.Log(ctx).Info("order placed", "catalog", cat, "checkout", out)
```

> **Watch the spelling:** the field is `trace_id` on purpose. Grafana's Loki datasource has a
> "derived field" regex expecting exactly that, and Alloy promotes it to structured metadata
> under the same name, which turns the ID into a clickable link to the trace. A different
> spelling would silently break log↔trace correlation.

## 4. Profiles - pprof, scraped by Alloy

**Profiling** answers "where is the CPU actually going?" Go ships this built in via
`net/http/pprof`. [`httpx.NewMux`](../apps/otel-demo/internal/httpx/httpx.go#L31) registers
the pprof endpoints on the same port as everything else:

```go
mux.HandleFunc("/debug/pprof/profile", pprof.Profile)   // CPU profile, etc.
```

The app doesn't push profiles anywhere either. A pod annotation opts it into scraping
([`k8s/frontend.yaml`](../apps/otel-demo/k8s/frontend.yaml#L21)):

```yaml
annotations:
  pyroscope.io/scrape: "true"   # Alloy scrapes /debug/pprof -> Pyroscope
```

`payment` deliberately runs a tight hashing loop
([`burnCPU`](../apps/otel-demo/cmd/payment/main.go#L50)) so the flame graph in Pyroscope has
an obvious hot path to show off.

## Putting it together: one request, four signals

When a request hits `frontend`'s `/order` (from the web UI or the loadgen), it
produces all four at once:

1. **Trace:** a span for `GET /order` on `frontend`, with child spans on `catalog`
   (`query-inventory`) and `checkout` → `payment` (`authorize-card`) - one connected
   waterfall, thanks to context propagation.
2. **Metrics:** the RED histograms tick up on every service, and `demo_orders` increments.
3. **Logs:** `"order placed"`, `"checkout complete"`, `"payment authorized"` - each tagged
   with the same `trace_id`, so they're one click away from the trace above.
4. **Profiles:** `payment`'s CPU time shows up in `burnCPU` in the flame graph.

## The three ideas to take away

If you remember nothing else about instrumenting a service with OTel:

1. **Initialize once, then thread `ctx` everywhere.** One `telemetry.Init()` call sets up
   the SDK; passing `r.Context()` through every call is what stitches spans and logs
   together across service boundaries.
2. **Prefer automatic instrumentation.** Wrapping HTTP handlers/clients in `otelhttp` gives
   you spans, RED metrics, and trace propagation for free. Write manual spans only for
   sub-operations worth highlighting.
3. **The app emits; the platform collects.** The service pushes traces to a collector,
   exposes `/metrics` and `/debug/pprof`, and prints logs to stdout. It never names Tempo,
   Loki, Mimir, or Pyroscope - collectors handle delivery, so backends can change without
   code changes.

## Where to look next

- [`internal/telemetry/telemetry.go`](../apps/otel-demo/internal/telemetry/telemetry.go) -
  the whole SDK setup, ~110 lines.
- [`internal/httpx/httpx.go`](../apps/otel-demo/internal/httpx/httpx.go) - the instrumented
  server and client.
- Any `cmd/*/main.go` - see how a real handler uses the helpers.
- [architecture.md](./architecture.md) - how the collectors and stores are configured on
  the platform side.
</content>
</invoke>
