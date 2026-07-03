// checkout charges the order by calling the payment service.
package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/grafana-stack-demo/otel-demo/internal/httpx"
	"github.com/grafana-stack-demo/otel-demo/internal/telemetry"
)

func main() {
	ctx := context.Background()
	tel, err := telemetry.Init(ctx, "checkout")
	if err != nil {
		panic(err)
	}
	defer tel.Shutdown(context.Background())

	paymentURL := getenv("PAYMENT_URL", "http://payment:8080")
	client := httpx.Client()

	mux := httpx.NewMux()
	httpx.Handle(mux, "/checkout", "GET /checkout", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		// Forward any simulated-failure probability down to payment, where the
		// fault is actually injected.
		payURL := httpx.WithFailRate(paymentURL+"/pay", httpx.FailRate(r, 0))
		receipt, err := httpx.Get(ctx, client, payURL)
		if err != nil {
			telemetry.Log(ctx).Error("payment call failed", "err", err)
			http.Error(w, "payment unavailable", http.StatusBadGateway)
			return
		}
		telemetry.Log(ctx).Info("checkout complete", "receipt", receipt)
		fmt.Fprintf(w, "checkout(%s)", receipt)
	})

	telemetry.Log(ctx).Info("checkout listening", "addr", ":8080", "payment", paymentURL)
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
