# Observability Demo

A minimal, reproducible demo of the full Grafana observability stack running on a
local [kind](https://kind.sigs.k8s.io/) cluster. Telemetry is split between two
collectors:

- **kube-prometheus-stack** (Prometheus + operator + kube-state-metrics +
  node-exporter) scrapes **metrics** from every component via ServiceMonitors and
  remote-writes them to **Mimir**.
- **Grafana Alloy** collects the other three signals — **logs**, **traces**, and
  **profiles** — and ships them to Loki / Tempo / Pyroscope.

Everything is read back through **Grafana** (**L**oki / **G**rafana / **T**empo /
**M**imir, plus Pyroscope). **Headlamp** provides a web UI for browsing the
cluster itself. The web UIs are exposed as NodePort services and published on the
host via kind `extraPortMappings`, so they're reachable directly on `localhost`
(e.g. Grafana at `http://localhost:3000`, Headlamp at `http://localhost:4466`).

```
┌──────────────────────────────── kind cluster ─────────────────────────────────┐
│                                                                                │
│                          ┌───────────────┐                                     │
│                          │  workload &   │                                     │
│                          │  system pods  │                                     │
│                          └──▲─────────┬──┘                                     │
│    scrape /metrics          │         │  logs · traces · profiles              │
│    ┌────────────────────────┘         └────────────┐                           │
│    │                                                ▼                          │
│ ┌──┴─────────┐                                ┌───────────┐                    │
│ │ Prometheus │                                │   Alloy   │                    │
│ │   (KPS)    │                                └─────┬─────┘                    │
│ └──┬─────────┘                                      │  logs → Loki             │
│    │ remote_write                                   │  traces → Tempo          │
│    ▼                                                ▼  profiles → Pyroscope    │
│ ┌──────────┐                                 ┌───────────────┐                 │
│ │  Mimir   │◀── span / service-graph ───────┤ Loki  Tempo    │                 │
│ │          │    metrics (from Tempo)         │  Pyroscope    │                 │
│ └────┬─────┘                                 └───────┬───────┘                 │
│      │              provisioned datasources          │                         │
│      │                    ┌──────────┐               │                         │
│      └──────────────────▶ | Grafana  │ ◀────────────┘                         │
│                           └──────────┘                                         │
│                               ▲                                                │
│                               └── you (browser)                                │
│                                                                                │
└────────────────────────────────────────────────────────────────────────────────┘
```

Prometheus **scrapes** the pods (pull, via ServiceMonitors) and remote-writes to
Mimir; Alloy **receives/collects** logs, traces, and profiles and ships them to
Loki / Tempo / Pyroscope. Grafana reads all four backends.

## Prerequisites

`make`, `podman`, `kind`, `kubectl`, `helm`, and `python3` on your PATH.
Once `make` is available, run `make check-tools` to verify the rest.

This setup uses **Podman** as the container runtime. The Makefile exports
`KIND_EXPERIMENTAL_PROVIDER=podman` for you, so `kind` uses Podman automatically.

## Quick start

```bash
make up          # create cluster + deploy stack + Alloy + validate
make down        # delete the cluster
```

>[!INFO]
>Run `make help` to see every target.

## What gets deployed

Everything lands in the `observability` namespace and is installed via Helm with
locally controlled values files under [`helm/`](helm/).

| Component | Chart | Version | Mode | Storage |
|-----------|-------|---------|------|---------|
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | 87.5.1 | Prometheus + operator + kube-state-metrics + node-exporter (Grafana & Windows exporter disabled) | ephemeral (2h local retention) |
| Mimir     | `grafana/mimir-distributed` | 6.1.0 | minimal (1 replica/component, no zones/Kafka) | bundled MinIO |
| Loki      | `grafana/loki`   | 7.0.0  | SingleBinary (monolithic) | filesystem |
| Tempo     | `grafana-community/tempo`  | 2.2.3 | single binary (monolithic) | filesystem |
| Pyroscope | `grafana/pyroscope` | 2.1.0 | monolithic (`all` target) | filesystem |
| Grafana   | `grafana-community/grafana` | 12.7.2 | — | ephemeral |
| Alloy     | `grafana/alloy`  | 1.10.0 | DaemonSet collector (logs/traces/profiles) | — |
| Headlamp  | `headlamp/headlamp` | 0.43.0 | in-cluster dashboard (cluster-admin, no-login demo mode) | — |

### Metrics: Prometheus, not Alloy

kube-prometheus-stack owns metrics end to end. Its **Prometheus operator** turns
the ServiceMonitors emitted by each chart (`helm/*/values.yaml`) into scrape
targets, **kube-state-metrics** and **node-exporter** add cluster/node metrics,
and Prometheus **remote-writes** every sample to Mimir — which is what Grafana's
metrics datasource reads from. Prometheus keeps only a 2h local buffer since Mimir is the long-term store.
The control-plane monitors (kube-controller-manager / scheduler / etcd /
kube-proxy) are disabled because kind doesn't expose them for scraping.

### A note on Mimir

Mimir has **no** official single-binary/monolithic Helm chart — the only first-party
chart is `mimir-distributed` (microservices). To honour the "minimal" goal we run it
at the smallest supported scale: one replica per required component, zone-aware
replication off, ingest-storage (Kafka) off, and every optional component
(alertmanager, ruler, caches, overrides-exporter, query-scheduler) disabled. See
[`helm/mimir/values.yaml`](helm/mimir/values.yaml).

## How telemetry flows through Alloy

Alloy now handles three signals (metrics belong to Prometheus). The pipeline is
defined in [`helm/alloy/values.yaml`](helm/alloy/values.yaml):

- **Logs** → tails every pod's stdout/stderr via the Kubernetes API, writes to Loki.
- **Traces** → receives OTLP on `:4317` (gRPC) / `:4318` (HTTP), exports to Tempo.
- **Profiles** → scrapes pprof of pods annotated `pyroscope.io/scrape: "true"`, writes to Pyroscope.

To send traces from a demo app, point its OTLP exporter at the Alloy service:
`http://alloy.observability.svc.cluster.local:4318` (HTTP) or `:4317` (gRPC).

## Exposing the UIs (NodePort + extraPortMappings)

kind ships no cloud provider, and on WSL2 + rootless Podman the container
network isn't routable from the host — so a `type: LoadBalancer` VIP can't be
reached from a browser. Instead the web UIs are `type: NodePort` services on
fixed node ports, and the kind node publishes those ports on the host via
`extraPortMappings`:

| UI           | Service nodePort | Host URL |
|--------------|------------------|----------|
| Grafana      | 30000            | http://localhost:3000 |
| Alloy        | 30345            | http://localhost:12345 |
| Prometheus   | 30090            | http://localhost:9090 |
| Alertmanager | 30093            | http://localhost:9093 |
| Headlamp     | 30466            | http://localhost:4466 |

The node ports in [`helm/grafana/values.yaml`](helm/grafana/values.yaml),
[`helm/alloy/values.yaml`](helm/alloy/values.yaml),
[`helm/kube-prometheus-stack/values.yaml`](helm/kube-prometheus-stack/values.yaml),
and [`helm/headlamp/values.yaml`](helm/headlamp/values.yaml)
must match the `extraPortMappings` in [`kind/cluster.yaml`](kind/cluster.yaml).
Because those mappings are applied at cluster-creation time, **changing them
requires `make down && make up`**. Alloy's OTLP receiver ports (4317/4318) stay
cluster-internal — demo apps push to them via the in-cluster Service DNS.

```bash
make grafana-ui        # -> http://localhost:3000    (admin / admin)
make alloy-ui          # -> http://localhost:12345
make prometheus-ui     # -> http://localhost:9090
make alertmanager-ui   # -> http://localhost:9093
make headlamp-ui       # -> http://localhost:4466
```

### Headlamp: browsing the cluster

[Headlamp](https://github.com/kubernetes-sigs/headlamp) is a lightweight
Kubernetes dashboard for eyeballing the cluster — pods, deployments, logs, and
events across the `observability` and `otel-demo` namespaces — without dropping
to `kubectl`. It's deployed by default with `make up`.

For zero-friction local use it runs with
`config.unsafeUseServiceAccountToken: true` and a **cluster-admin** binding
(see [`helm/headlamp/values.yaml`](helm/headlamp/values.yaml)), so the UI opens
straight in with no token prompt. That means **no per-user auth** — it's fine for
a throwaway local kind cluster but must never be used on a shared or real one.

## Layout

```
.
├── Makefile               # orchestration (cluster, deploy, validate, teardown)
├── kind/cluster.yaml      # single-node kind cluster + UI port mappings
├── helm/<component>/values.yaml   # per-component Helm values (source of truth)
│                                  #   (grafana, alloy, mimir, loki, tempo,
│                                  #    pyroscope, kube-prometheus-stack, headlamp)
├── apps/otel-demo/        # OTel-instrumented demo app (own namespace)
├── scripts/
│   ├── lib.sh             # shared shell helpers
│   ├── validate.sh        # pods Ready + datasource health + UI reachability
│   └── demo-test.sh       # verify the demo app emits all four signals
└── docs/obs-architecture.md   # deeper design notes
```

## Cross-signal correlation

Grafana's Tempo datasource is pre-wired for trace → logs, trace → metrics
(service graph / span metrics), and trace → profiles, so the demo shows the full
correlated experience out of the box. See [`helm/grafana/values.yaml`](helm/grafana/values.yaml).

## Demo application

An OpenTelemetry-instrumented demo app ships in
[`apps/otel-demo/`](apps/otel-demo/). It's a small Go microservices app —
`frontend → {checkout → payment, catalog}` — that generates **all four
signals** and feeds them into **this stack's own collectors** (no bundled
collector/backends, unlike the upstream OpenTelemetry demo). It runs in its own
**`otel-demo`** namespace and requires **no changes to the stack**.

The **frontend serves an interactive web UI at `http://localhost:8080`** where
you place orders and drive load by hand. A **`loadgen`** sidecar is included as
an *optional* background traffic driver (toggle with `DEMO_LOADGEN`).

| Signal   | App emits | Stack collects |
|----------|-----------|----------------|
| Traces   | OTLP/gRPC → Alloy | Alloy → Tempo |
| Metrics  | `/metrics` (OTel Prometheus exporter) + `PodMonitor` | Prometheus → remote_write → Mimir |
| Logs     | `slog` JSON to stdout with a `trace_id` field | Alloy pod-log tail → Loki (auto-linked to traces) |
| Profiles | Go `pprof` + `pyroscope.io/scrape` annotation | Alloy → Pyroscope |

```bash
make demo                      # build images, load into kind, deploy the app
make demo DEMO_LOADGEN=false   # deploy without the background loadgen
make demo-ui                   # print the web UI URL (http://localhost:8080)
make demo-test                 # assert all four signals are flowing end to end
make demo-clean                # remove the demo (delete its namespace)
```

Open the **web UI at `http://localhost:8080`** to place orders and drive load,
then open Grafana (`http://localhost:3000`, admin/admin) and:

- **Explore → Tempo**: search `service.name=frontend`; open a trace spanning
  frontend → checkout → payment / catalog, and view the service graph. From a
  span, follow the pre-wired links to logs, metrics, and profiles.
- **Explore → Loki**: `{namespace="otel-demo"}`; click a line's `trace_id` to jump
  to its Tempo trace.
- **Explore → Mimir**: query `demo_orders_total` or
  `http_server_request_duration_seconds_count`.
- **Explore → Pyroscope**: flame graph for the `payment` service shows the CPU
  hot path.

See [`apps/otel-demo/README.md`](apps/otel-demo/README.md) for the instrumentation
walkthrough.
