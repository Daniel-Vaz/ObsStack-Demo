// payment simulates charging a card. It deliberately burns CPU (a hashing loop)
// so Pyroscope flame graphs have a clear hot path to show.
package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/grafana-stack-demo/otel-demo/internal/httpx"
	"github.com/grafana-stack-demo/otel-demo/internal/telemetry"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/metric"
)

// errCardDeclined is the simulated failure payment injects when a request is
// selected to fail. It's a business-level error (not an outage), so it reads
// like something you'd genuinely alert on.
var errCardDeclined = errors.New("card declined: insufficient funds")

// defaultBurnIterations is sized against the Go CPU profiler's 10ms sampling
// interval, not for realism: at ~8ns per sha256 round this is roughly 25ms of
// CPU per request, so each /pay span reliably collects two or three stack
// samples.
//
// This matters for *span* profiles specifically. A span whose CPU time lands
// under one sampling interval usually gets zero samples, so Grafana's embedded
// "profiles for this span" flame graph comes back empty even though everything
// is wired correctly - the request simply finished between two samples. The
// earlier value (15000, ~2ms) demonstrated the service-level flame graph fine
// but was invisible per-span. Override with PAYMENT_BURN_ITERATIONS.
const defaultBurnIterations = 200000

func main() {
	ctx := context.Background()
	tel, err := telemetry.Init(ctx, "payment")
	if err != nil {
		panic(err)
	}
	defer tel.Shutdown(context.Background())

	tracer := otel.Tracer("payment")

	// Baseline failure probability for traffic that doesn't carry a per-request
	// fail_rate (e.g. the optional loadgen). The web UI overrides this per call.
	defaultFailRate := getfloat("FAIL_RATE", 0)
	burnIterations := getint("PAYMENT_BURN_ITERATIONS", defaultBurnIterations)

	// A dedicated business counter for simulated declines, exported to
	// Prometheus as demo_payment_failures_total - the signal the PrometheusRule
	// alerts on. (otelhttp also records the 500s under
	// http_server_request_duration_seconds_count{http_response_status_code="500"}.)
	failures, err := otel.Meter("payment").Int64Counter("demo_payment_failures",
		metric.WithDescription("simulated payment authorization failures"))
	if err != nil {
		panic(err)
	}

	mux := httpx.NewMux()
	httpx.Handle(mux, "/pay", "GET /pay", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()

		_, span := tracer.Start(ctx, "authorize-card")
		defer span.End()
		sum := burnCPU(burnIterations) // hashing hot path, visible in the flame graph

		// Simulated failure: record it on the span (error status + exception
		// event), bump the metric, log at error level, and return 500. All three
		// signals - trace, metric, log - light up for the same event.
		if httpx.ShouldFail(r, defaultFailRate) {
			span.RecordError(errCardDeclined)
			span.SetStatus(codes.Error, errCardDeclined.Error())
			failures.Add(ctx, 1)
			telemetry.Log(ctx).Error("payment declined", "err", errCardDeclined)
			http.Error(w, "payment declined", http.StatusInternalServerError)
			return
		}

		telemetry.Log(ctx).Info("payment authorized")
		fmt.Fprintf(w, "paid#%s", strconv.FormatUint(uint64(sum[0]), 16))
	})

	telemetry.Log(ctx).Info("payment listening", "addr", ":8080")
	srv := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		telemetry.Log(ctx).Error("server stopped", "err", err)
		os.Exit(1)
	}
}

func getfloat(key string, def float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}

func getint(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return def
}

// burnCPU repeatedly hashes to create a recognisable CPU hot spot for profiling.
func burnCPU(iterations int) [32]byte {
	var sum [32]byte
	buf := []byte("charge")
	for i := 0; i < iterations; i++ {
		sum = sha256.Sum256(buf)
		buf = sum[:]
	}
	return sum
}
