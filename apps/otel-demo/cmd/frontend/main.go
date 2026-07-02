// frontend is the entry point of the demo app. Each request fans out to
// checkout and catalog, producing a two-level distributed trace.
package main

import (
	"context"
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

	orders, err := otel.Meter("frontend").Int64Counter("demo_orders",
		metric.WithDescription("orders placed through the frontend"))
	if err != nil {
		panic(err)
	}

	mux := httpx.NewMux()
	httpx.Handle(mux, "/", "GET /", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()

		cat, err := httpx.Get(ctx, client, catalogURL+"/products")
		if err != nil {
			telemetry.Log(ctx).Error("catalog call failed", "err", err)
			http.Error(w, "catalog unavailable", http.StatusBadGateway)
			return
		}
		out, err := httpx.Get(ctx, client, checkoutURL+"/checkout")
		if err != nil {
			telemetry.Log(ctx).Error("checkout call failed", "err", err)
			http.Error(w, "checkout unavailable", http.StatusBadGateway)
			return
		}

		orders.Add(ctx, 1, metric.WithAttributes(attribute.String("route", "/")))
		telemetry.Log(ctx).Info("order placed", "catalog", cat, "checkout", out)
		fmt.Fprintf(w, "order ok: %s | %s\n", cat, out)
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
