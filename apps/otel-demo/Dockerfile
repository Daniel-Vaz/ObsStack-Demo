# Multi-stage build shared by every demo service.
# Select which service to build with:  --build-arg SERVICE=<frontend|checkout|payment|catalog|loadgen>
FROM golang:1.25-bookworm AS build
WORKDIR /src

# Cache the module layer: deps only re-download when go.mod/go.sum change.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
ARG SERVICE
RUN test -n "$SERVICE" || { echo "SERVICE build-arg is required"; exit 1; }
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -o /out/app ./cmd/${SERVICE}

# Distroless static: tiny, no shell; runs as non-root (uid 65532) on port 8080.
FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
