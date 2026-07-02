// payment simulates charging a card. It deliberately burns CPU (a hashing loop)
// so Pyroscope flame graphs have a clear hot path to show.
package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/grafana-stack-demo/otel-demo/internal/httpx"
	"github.com/grafana-stack-demo/otel-demo/internal/telemetry"
	"go.opentelemetry.io/otel"
)

func main() {
	ctx := context.Background()
	tel, err := telemetry.Init(ctx, "payment")
	if err != nil {
		panic(err)
	}
	defer tel.Shutdown(context.Background())

	tracer := otel.Tracer("payment")

	mux := httpx.NewMux()
	httpx.Handle(mux, "/pay", "GET /pay", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()

		_, span := tracer.Start(ctx, "authorize-card")
		sum := burnCPU(15000) // ~ a few ms of hashing, visible in the flame graph
		span.End()

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
