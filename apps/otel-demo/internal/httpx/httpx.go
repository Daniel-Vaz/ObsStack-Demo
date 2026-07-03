// Package httpx provides the small HTTP glue shared by every demo service:
// an OTel-instrumented server mux (with /metrics and /debug/pprof wired in) and
// a trace-propagating HTTP client.
package httpx

import (
	"context"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"net/http/pprof"
	"strconv"
	"strings"
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
//
// A non-2xx response is returned as an error so a simulated failure injected
// deep in the call chain (see FailRate) propagates back up: each service sees
// its downstream call fail, marks its own span as errored, logs, and returns
// 5xx — producing a full distributed-error trace instead of a silent 500.
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
	if err != nil {
		return "", err
	}
	if resp.StatusCode >= http.StatusBadRequest {
		return string(body), fmt.Errorf("GET %s: status %d: %s", url, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return string(body), nil
}

// FailRate reads the simulated-failure probability (0..1) a request carries in
// its ?fail_rate= query param, falling back to def when the param is absent or
// unparseable. The demo's web UI sets this so you can dial error frequency up
// and down and watch it surface across metrics, traces and logs.
func FailRate(r *http.Request, def float64) float64 {
	if v := r.URL.Query().Get("fail_rate"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return clamp01(f)
		}
	}
	return clamp01(def)
}

// ShouldFail rolls the dice once for this request: it returns true with
// probability FailRate(r, def), i.e. whether this request should be failed on
// purpose.
func ShouldFail(r *http.Request, def float64) bool {
	return rand.Float64() < FailRate(r, def)
}

// WithFailRate appends the fail_rate query param to a downstream URL so the
// simulated-failure probability propagates along the call chain. A rate <= 0
// leaves the URL untouched (so a downstream service keeps its own env default).
func WithFailRate(url string, rate float64) string {
	if rate <= 0 {
		return url
	}
	sep := "?"
	if strings.Contains(url, "?") {
		sep = "&"
	}
	return fmt.Sprintf("%s%sfail_rate=%g", url, sep, rate)
}

func clamp01(f float64) float64 {
	switch {
	case f < 0:
		return 0
	case f > 1:
		return 1
	default:
		return f
	}
}
