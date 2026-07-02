// Package httpx provides the small HTTP glue shared by every demo service:
// an OTel-instrumented server mux (with /metrics and /debug/pprof wired in) and
// a trace-propagating HTTP client.
package httpx

import (
	"context"
	"io"
	"net/http"
	"net/http/pprof"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// NewMux returns a ServeMux with the infrastructure endpoints already
// registered on a single port:
//
//	/metrics          Prometheus exposition (OTel Prometheus exporter)
//	/debug/pprof/...  Go pprof, scraped by Alloy into Pyroscope
//	/healthz          liveness/readiness
//
// Keeping everything on one container port means Alloy's pod discovery resolves
// exactly one Pyroscope scrape target — no extra collector config needed.
func NewMux() *http.ServeMux {
	mux := http.NewServeMux()

	mux.Handle("/metrics", promhttp.Handler())

	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "ok")
	})

	return mux
}

// Handle registers an application route wrapped in otelhttp so each request
// gets a server span named op. Infrastructure endpoints above are deliberately
// left unwrapped to keep scrape traffic out of the traces.
func Handle(mux *http.ServeMux, pattern, op string, h http.HandlerFunc) {
	mux.Handle(pattern, otelhttp.NewHandler(h, op))
}

// Client is a trace-propagating HTTP client: otelhttp injects the W3C
// traceparent header so downstream services join the same trace.
func Client() *http.Client {
	return &http.Client{
		Timeout:   5 * time.Second,
		Transport: otelhttp.NewTransport(http.DefaultTransport),
	}
}

// Get performs a context-propagating GET and returns the response body. The
// caller's span context (ctx) flows to the downstream service.
func Get(ctx context.Context, client *http.Client, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	return string(body), err
}
