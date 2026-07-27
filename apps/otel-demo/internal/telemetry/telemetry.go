// Package telemetry wires an OTel-instrumented Go service into the demo's
// Grafana LGTM stack. One Init call sets up all four signals:
//
//	traces   -> OTLP/gRPC to Alloy (env OTEL_EXPORTER_OTLP_ENDPOINT) -> Tempo
//	metrics  -> Prometheus exporter on /metrics, scraped by kube-prometheus-stack -> Mimir
//	logs     -> slog JSON to stdout (tailed by Alloy) -> Loki
//	profiles -> net/http/pprof, scraped by Alloy -> Pyroscope  (see internal/httpx)
//
// The logger injects the active span's trace id under the key "trace_id" so
// Grafana's Loki datasource links each log line to its Tempo trace out of the
// box (Alloy also promotes it to structured metadata under the same name).
//
// Traces and profiles are joined the same way, one layer down: the tracer
// provider is wrapped by otel-profiling-go, which tags the Go runtime's pprof
// labels with trace_id/span_id so the scraped CPU profile carries them into
// Pyroscope. See docs/correlation.md for the full cross-signal picture.
package telemetry

import (
	"context"
	"errors"
	"log/slog"
	"os"

	otelpyroscope "github.com/grafana/otel-profiling-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	otelprom "go.opentelemetry.io/otel/exporters/prometheus"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// Providers bundles the initialised OTel handles and a shutdown hook.
type Providers struct {
	Tracer   trace.Tracer
	shutdown []func(context.Context) error
}

// Shutdown flushes and stops every provider. Call it on process exit so the
// last batch of spans reaches Tempo.
func (p *Providers) Shutdown(ctx context.Context) error {
	var err error
	for _, fn := range p.shutdown {
		err = errors.Join(err, fn(ctx))
	}
	return err
}

// Init configures traces, metrics, logging and propagation for serviceName.
// The OTLP endpoint is taken from the standard OTEL_EXPORTER_OTLP_* env vars.
func Init(ctx context.Context, serviceName string) (*Providers, error) {
	version := getenv("SERVICE_VERSION", "0.1.0")

	res, err := resource.New(ctx, resource.WithAttributes(
		attribute.String("service.name", serviceName),
		attribute.String("service.namespace", "otel-demo"),
		attribute.String("service.version", version),
		attribute.String("deployment.environment", "demo"),
	))
	if err != nil {
		return nil, err
	}

	// --- Traces: OTLP/gRPC to Alloy (endpoint + insecure come from env) ---
	texp, err := otlptracegrpc.New(ctx)
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(texp),
		sdktrace.WithResource(res),
	)

	// Wrap the provider so every span also annotates the Go runtime's pprof
	// labels with its trace/span id, and stamps a "pyroscope.profile.id"
	// attribute on the local root span. That attribute is what makes Grafana
	// render an *embedded* flame graph inside the span detail - profiles for
	// this exact span, not just for this service at this time.
	//
	// This needs no Pyroscope SDK and no push: otelpyroscope only calls
	// runtime/pprof.SetGoroutineLabels, so the labels ride along in the CPU
	// profile Alloy already scrapes from /debug/pprof/profile. The app still
	// pushes nothing and still names no backend.
	//
	// Defaults are deliberate: span_id/span_name are recorded for the *local
	// root span* only (child spans' samples roll up into it), which keeps
	// Pyroscope's label cardinality to one series per inbound request instead
	// of one per span. See docs/correlation.md.
	traced := otelpyroscope.NewTracerProvider(tp)
	otel.SetTracerProvider(traced)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))

	// --- Metrics: OTel SDK -> Prometheus exporter (served on /metrics) ---
	mexp, err := otelprom.New()
	if err != nil {
		return nil, err
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(mexp),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	// --- Logs: structured JSON to stdout, tailed by Alloy into Loki ---
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})).With("service", serviceName))

	return &Providers{
		// Tracer comes from the wrapped provider so manually-created spans get
		// the pprof labels too; shutdown stays on the raw SDK provider, which
		// is the one that actually owns the batcher.
		Tracer:   traced.Tracer(serviceName),
		shutdown: []func(context.Context) error{tp.Shutdown, mp.Shutdown},
	}, nil
}

// Log returns the default logger enriched with the trace/span ids from ctx, so
// every line correlates to its Tempo trace via the "trace_id" field.
func Log(ctx context.Context) *slog.Logger {
	l := slog.Default()
	if sc := trace.SpanContextFromContext(ctx); sc.HasTraceID() {
		l = l.With("trace_id", sc.TraceID().String(), "span_id", sc.SpanID().String())
	}
	return l
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
