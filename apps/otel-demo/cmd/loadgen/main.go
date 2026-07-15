// loadgen continuously drives the frontend so the stack always has live
// telemetry. It is a client only: no server, no /metrics, not profiled - but it
// still emits its own client spans (root of each trace) and stdout logs.
package main

import (
	"context"
	"os"
	"time"

	"github.com/grafana-stack-demo/otel-demo/internal/httpx"
	"github.com/grafana-stack-demo/otel-demo/internal/telemetry"
	"go.opentelemetry.io/otel"
)

func main() {
	ctx := context.Background()
	tel, err := telemetry.Init(ctx, "loadgen")
	if err != nil {
		panic(err)
	}
	defer tel.Shutdown(context.Background())

	frontendURL := getenv("FRONTEND_URL", "http://frontend:8080")
	interval := getdur("REQUEST_INTERVAL", 500*time.Millisecond)
	client := httpx.Client()
	tracer := otel.Tracer("loadgen")

	telemetry.Log(ctx).Info("loadgen starting", "target", frontendURL, "interval", interval)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for range ticker.C {
		reqCtx, span := tracer.Start(ctx, "place-order")
		if _, err := httpx.Get(reqCtx, client, frontendURL+"/order"); err != nil {
			telemetry.Log(reqCtx).Warn("request failed", "err", err)
		}
		span.End()
	}
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getdur(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}
