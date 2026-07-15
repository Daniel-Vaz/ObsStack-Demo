// frontend is the entry point of the demo app. It serves an interactive web UI
// (index.html) for driving traffic by hand and the /order route that fans out
// to checkout and catalog, producing a two-level distributed trace.
package main

import (
	"context"
	_ "embed"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/grafana-stack-demo/otel-demo/internal/httpx"
	"github.com/grafana-stack-demo/otel-demo/internal/telemetry"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

// index.html is the interactive traffic console served at "/". Embedding it
// keeps the image a single static binary with no runtime asset dependencies.
//
//go:embed index.html
var indexHTML []byte

func main() {
	ctx := context.Background()
	tel, err := telemetry.Init(ctx, "frontend")
	if err != nil {
		panic(err)
	}
	defer tel.Shutdown(context.Background())

	checkoutURL := getenv("CHECKOUT_URL", "http://checkout:8080")
	catalogURL := getenv("CATALOG_URL", "http://catalog:8080")
	client := httpx.Client()

	meter := otel.Meter("frontend")
	orders, err := meter.Int64Counter("demo_orders",
		metric.WithDescription("orders placed through the frontend"))
	if err != nil {
		panic(err)
	}
	// demo_order_errors_total: orders that failed end-to-end, including the
	// simulated faults injected downstream. This is the ratio's numerator in the
	// PrometheusRule (errors / (orders + errors)).
	orderErrors, err := meter.Int64Counter("demo_order_errors",
		metric.WithDescription("orders that failed (including simulated faults)"))
	if err != nil {
		panic(err)
	}

	mux := httpx.NewMux()

	// Web UI: a small interactive page for generating traffic by hand, so the
	// stack has live telemetry even when the loadgen is not deployed. Served
	// unwrapped (no server span) - page loads aren't part of the order flow.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(indexHTML)
	})

	// Place an order: fan out to catalog + checkout. This is the traced
	// business flow the loadgen and the UI's "Place order" button both drive.
	httpx.Handle(mux, "/order", "GET /order", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		route := metric.WithAttributes(attribute.String("route", "/order"))

		// Simulated-failure probability from the web UI (?fail_rate=0..1),
		// forwarded downstream to payment where the fault is injected.
		failRate := httpx.FailRate(r, 0)

		cat, err := httpx.Get(ctx, client, catalogURL+"/products")
		if err != nil {
			orderErrors.Add(ctx, 1, route)
			telemetry.Log(ctx).Error("catalog call failed", "err", err)
			http.Error(w, "catalog unavailable", http.StatusBadGateway)
			return
		}
		out, err := httpx.Get(ctx, client, httpx.WithFailRate(checkoutURL+"/checkout", failRate))
		if err != nil {
			orderErrors.Add(ctx, 1, route)
			telemetry.Log(ctx).Error("checkout call failed", "err", err)
			http.Error(w, "checkout unavailable", http.StatusBadGateway)
			return
		}

		orders.Add(ctx, 1, route)
		telemetry.Log(ctx).Info("order placed", "catalog", cat, "checkout", out)
		fmt.Fprintf(w, "order ok: %s | %s\n", cat, out)
	})

	// Browse the catalog only: a lighter call that skips checkout/payment, so
	// the UI can produce a shorter trace shape too.
	httpx.Handle(mux, "/catalog", "GET /catalog", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()

		cat, err := httpx.Get(ctx, client, catalogURL+"/products")
		if err != nil {
			telemetry.Log(ctx).Error("catalog call failed", "err", err)
			http.Error(w, "catalog unavailable", http.StatusBadGateway)
			return
		}
		telemetry.Log(ctx).Info("catalog browsed", "catalog", cat)
		fmt.Fprintf(w, "catalog: %s\n", cat)
	})

	telemetry.Log(ctx).Info("frontend listening", "addr", ":8080",
		"checkout", checkoutURL, "catalog", catalogURL)
	srv := &http.Server{Addr: ":8080", Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if err := srv.ListenAndServe(); err != nil {
		telemetry.Log(ctx).Error("server stopped", "err", err)
		os.Exit(1)
	}
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
