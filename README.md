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
cluster itself, and **Karma** provides an alert dashboard over Alertmanager. The
web UIs are exposed as NodePort services and published on the
host via kind `extraPortMappings`, so they're reachable directly on `localhost`
(e.g. Grafana at `http://localhost:3000`, Headlamp at `http://localhost:4466`).

![Grafana Kubernetes / Compute Resources / Cluster dashboard showing CPU and memory utilisation panels by namespace](docs/images/grafana-dashboard-example.png)
*Grafana at `http://localhost:3000`, rendering a stock Kubernetes dashboard from metrics scraped by Prometheus and stored in Mimir — one of the many views this stack lights up.*

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

>[!NOTE]
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
| Karma     | `helm/karma` (first-party) | v0.131 | alert dashboard over Alertmanager (reads all alerts) | — |

Alongside the stack, `make up` also builds and deploys the **OpenTelemetry demo
app** (`otel-demo-app`) into its own `otel-demo` namespace — via plain
Kubernetes manifests rather than Helm. See [Demo application](#demo-application)
below.

## Exposing the UIs (NodePort + extraPortMappings)

The web UIs are `type: NodePort` services on fixed node ports, and the 
kind node publishes those ports on the host via `extraPortMappings`:

| UI            | Service nodePort | Host URL |
|---------------|------------------|----------|
| Grafana       | 30000            | http://localhost:3000  |
| Alloy         | 30345            | http://localhost:12345 |
| Prometheus    | 30090            | http://localhost:9090  |
| Alertmanager  | 30093            | http://localhost:9093  |
| Karma         | 30081            | http://localhost:8081  |
| Headlamp      | 30466            | http://localhost:4466  |
| Otel-Demo-App | 30080            | http://localhost:8080  |

The node ports in [`helm/grafana/values.yaml`](helm/grafana/values.yaml),
[`helm/alloy/values.yaml`](helm/alloy/values.yaml),
[`helm/kube-prometheus-stack/values.yaml`](helm/kube-prometheus-stack/values.yaml),
[`helm/karma/values.yaml`](helm/karma/values.yaml),
and [`helm/headlamp/values.yaml`](helm/headlamp/values.yaml)
must match the `extraPortMappings` in [`kind/cluster.yaml`](kind/cluster.yaml).
Because those mappings are applied at cluster-creation time, **changing them
requires `make down && make up`**. Alloy's OTLP receiver ports (4317/4318) stay
cluster-internal — demo apps push to them via the in-cluster Service DNS.

## Layout

```
.
├── Makefile                       # orchestration (cluster, deploy, validate, teardown)
├── kind/cluster.yaml              # single-node kind cluster + UI port mappings
├── helm/<component>/values.yaml   # per-component Helm values (source of truth)
├── apps/otel-demo/                # OTel-instrumented demo app (own namespace)
├── scripts/
│   ├── lib.sh                     # shared shell helpers
│   ├── validate.sh                # pods Ready + datasource health + UI reachability
│   └── demo-test.sh               # verify the demo app emits all four signals
└── docs/
    ├── architecture.md            # deeper design notes (the "why")
    ├── otel-instrumentation.md    # how the demo app is OTel-instrumented
    └── solutions/                 # per-tool intro guides (start here to learn each tool)
```

## Learn the tools

New to the Grafana observability stack? [`docs/solutions/`](docs/solutions/) has a
short, beginner-friendly guide to each tool in this demo — what it is, what it's
for, and how it's wired in here:

- [Kube-Prometheus-Stack](docs/solutions/kube-prometheus-stack.md) — metrics collection (Prometheus, operator, exporters, Alertmanager)
- [Mimir](docs/solutions/mimir.md) — long-term metrics storage
- [Loki](docs/solutions/loki.md) — logs storage
- [Tempo](docs/solutions/tempo.md) — traces storage
- [Pyroscope](docs/solutions/pyroscope.md) — continuous profiling
- [Alloy](docs/solutions/alloy.md) — the collection pipeline
- [Karma](docs/solutions/karma.md) — alert dashboard for Alertmanager
- [Headlamp](docs/solutions/headlamp.md) — cluster UI
- [Kind & Podman](docs/solutions/kind-and-podman.md) — the local platform

## Demo application

An OpenTelemetry-instrumented demo app ships in
[`apps/otel-demo/`](apps/otel-demo/). It's a small Go microservices app —
`frontend → {checkout → payment, catalog}` — that generates **all four
signals** and feeds them into **this stack's own collectors** (no bundled
collector/backends, unlike the upstream OpenTelemetry demo). It runs in its own
**`otel-demo`** namespace and requires **no changes to the stack**.

The **frontend serves an interactive web UI at `http://localhost:8080`** where
you place orders and drive load by hand — that's the default. A **`loadgen`** is
included as an *optional* background traffic driver, **off by default**; deploy it
with `DEMO_LOADGEN=true`.

![otel-demo traffic console at localhost:8080 — Place order / Browse catalog / Send burst controls, a live request counter, and a response log](docs/images/oteldemoapp-ui.png)
*The demo app's traffic console — place orders or flip on *Auto load* to generate the traces, metrics, logs, and profiles you then explore in Grafana.*

| Signal   | App emits | Stack collects |
|----------|-----------|----------------|
| Traces   | OTLP/gRPC → Alloy | Alloy → Tempo |
| Metrics  | `/metrics` (OTel Prometheus exporter) + `PodMonitor` | Prometheus → remote_write → Mimir |
| Logs     | `slog` JSON to stdout with a `trace_id` field | Alloy pod-log tail → Loki (auto-linked to traces) |
| Profiles | Go `pprof` + `pyroscope.io/scrape` annotation | Alloy → Pyroscope |

```bash
make demo                      # build images, load into kind, deploy the app (no loadgen)
make demo DEMO_LOADGEN=true    # also deploy the background loadgen
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

![Grafana Explore split view: a Tempo trace on the left linked to its correlated Loki log line on the right by trace_id](docs/images/grafana-traces-to-logs.png)
*The payoff of a correlated stack: from a `frontend → checkout → payment / catalog` trace in Tempo (left), one click on `Logs for this span` lands on the exact log line in Loki (right), joined by `trace_id`.*

See [`apps/otel-demo/README.md`](apps/otel-demo/README.md) for the instrumentation
walkthrough.
