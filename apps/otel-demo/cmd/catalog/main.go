// catalog returns a product list after a small, variable latency (so trace
// waterfalls and latency histograms have something to show).
package main

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"os"
	"time"

	"github.com/grafana-stack-demo/otel-demo/internal/httpx"
	"github.com/grafana-stack-demo/otel-demo/internal/telemetry"
	"go.opentelemetry.io/otel"
)

var products = []string{"telescope", "compass", "sextant", "astrolabe"}

func main() {
	ctx := context.Background()
	tel, err := telemetry.Init(ctx, "catalog")
	if err != nil {
		panic(err)
	}
	defer tel.Shutdown(context.Background())

	tracer := otel.Tracer("catalog")

	mux := httpx.NewMux()
	httpx.Handle(mux, "/products", "GET /products", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()

		_, span := tracer.Start(ctx, "query-inventory")
		time.Sleep(time.Duration(5+rand.Intn(40)) * time.Millisecond)
		span.End()

		telemetry.Log(ctx).Info("catalog served", "count", len(products))
		fmt.Fprintf(w, "%d products", len(products))
	})

	telemetry.Log(ctx).Info("catalog listening", "addr", ":8080")
	srv := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		telemetry.Log(ctx).Error("server stopped", "err", err)
		os.Exit(1)
	}
}
