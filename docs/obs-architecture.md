# Architecture & design notes

This document records the *why* behind the setup. For usage, see the [README](../README.md).

## Goals

- **Minimal**: smallest footprint that still demonstrates all four signals end to end,
  suitable for a laptop-sized kind cluster.
- **Monolithic backends**: each backend runs as a single binary / single replica.
- **Helm-managed, values as source of truth**: every component is a Helm release with a
  local `values.yaml`; nothing is configured imperatively.
- **Metrics via Prometheus, everything else via Alloy**: kube-prometheus-stack's Prometheus
  scrapes metrics from ServiceMonitors and remote-writes to Mimir; a single Grafana Alloy
  pipeline handles logs, traces, and profiles.
- **Zero-friction UI access**: the web UIs are reachable on `localhost` out of the box, with
  no `kubectl port-forward`, via NodePort services + kind `extraPortMappings`.

## Component modes

| Component | Monolithic mechanism |
|-----------|----------------------|
| Loki      | `deploymentMode: SingleBinary`, scalable workloads scaled to 0, filesystem storage |
| Tempo     | `grafana/tempo` chart *is* the single-binary deployment; filesystem storage |
| Pyroscope | chart runs the `all` target as one StatefulSet by default |
| Mimir     | no monolithic chart exists — see below |

### Mimir: the exception

There is no first-party single-binary/monolithic Mimir Helm chart. The only official
chart, `grafana/mimir-distributed`, is microservices. We deploy it at the minimum viable
scale rather than introducing a non-Helm install:

- `kafka.enabled: false` → classic push architecture (no Kafka statefulset / block-builder).
- `ingester` / `store_gateway` `zoneAwareReplication.enabled: false` → one replica each
  instead of three zones; `rollout_operator` disabled (only needed for zoned rollouts).
- `ingester.ring.replication_factor: 1` (single ingester).
- `query_scheduler` kept at 1 replica — the base config points the querier's
  `frontend_worker` at the scheduler, so removing it hangs the read path.
- `alertmanager`, `ruler`, `overrides_exporter`, and all memcached caches disabled.
- Bundled MinIO provides object storage.

Result: distributor, ingester, querier, query-frontend, query-scheduler, compactor,
store-gateway, gateway, minio — one pod each instead of the ~17 the defaults render.

## Metrics collection: kube-prometheus-stack

Metrics are owned by [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
(`prometheus-community/kube-prometheus-stack`), not Alloy. See
[`helm/kube-prometheus-stack/values.yaml`](../helm/kube-prometheus-stack/values.yaml).

- **What we deploy**: Prometheus, Alertmanager, the Prometheus operator,
  kube-state-metrics, and node-exporter.
- **What we disable**: the bundled Grafana (`grafana.enabled: false` — Grafana has its own
  release) and the Windows exporter (`windowsMonitoring.enabled: false` — no Windows nodes).
- **Discovery via ServiceMonitors**: each other chart emits a ServiceMonitor
  (`serviceMonitor.enabled` / `metaMonitoring.serviceMonitor.enabled` /
  `monitoring.serviceMonitor.enabled`), and the operator converts those into scrape targets.
  Because those ServiceMonitors don't carry the KPS release label, we set
  `serviceMonitorSelectorNilUsesHelmValues: false` and empty selectors so Prometheus
  selects **all** ServiceMonitors/PodMonitors in **all** namespaces.
- **remote_write to Mimir**: `prometheusSpec.remoteWrite` points at
  `http://mimir-gateway.observability.svc.cluster.local/api/v1/push`. Prometheus keeps a
  2h local buffer (`retention: 2h`); Mimir is the long-term store and the source Grafana
  reads from.
- **kind noise removed**: the `kubeControllerManager` / `kubeScheduler` / `kubeEtcd` /
  `kubeProxy` component monitors are disabled because kind doesn't expose those endpoints
  for scraping, so they'd otherwise sit permanently "down".

CRD ordering: KPS installs the Prometheus-operator CRDs (ServiceMonitor, PodMonitor, …).
Since every other chart's values now reference those CRDs, `make stack` deploys KPS first.

## Exposing the UIs: NodePort + extraPortMappings

kind provisions no cloud controller, so a `type: LoadBalancer` service never gets an
external IP — it sits `<pending>`. A load balancer (e.g. MetalLB) *can* hand out a VIP,
but that VIP lives on the kind/Podman container network, which on **WSL2 + rootless
Podman is not routable from the host** — so a browser can't reach it. Podman only
publishes explicitly mapped ports to the host's loopback.

So we expose the UIs the way that actually works on this setup:

- `service.type: NodePort` with a **pinned** `nodePort` on
  [`helm/grafana/values.yaml`](../helm/grafana/values.yaml) (30000),
  [`helm/alloy/values.yaml`](../helm/alloy/values.yaml) (30345 for the UI / http-metrics
  port), and [`helm/kube-prometheus-stack/values.yaml`](../helm/kube-prometheus-stack/values.yaml)
  (30090 for Prometheus, 30093 for Alertmanager). The Alloy chart also passes `nodePort`
  through on `extraPorts`, but the OTLP ports are deliberately left unpinned — they stay
  cluster-internal.
- [`kind/cluster.yaml`](../kind/cluster.yaml) `extraPortMappings` publish those node ports
  on the host: `3000 -> 30000` (Grafana), `12345 -> 30345` (Alloy), `9090 -> 30090`
  (Prometheus), `9093 -> 30093` (Alertmanager). kind wires the host port straight to the
  node container's port, and kube-proxy routes the nodePort to the pod.

| UI           | nodePort | Host URL |
|--------------|----------|----------|
| Grafana      | 30000    | http://localhost:3000 |
| Alloy        | 30345    | http://localhost:12345 |
| Prometheus   | 30090    | http://localhost:9090 |
| Alertmanager | 30093    | http://localhost:9093 |

`extraPortMappings` are fixed at cluster-creation time, so the port pairs in
`kind/cluster.yaml` and the chart values must stay in sync, and changing them needs a
`make down && make up`.

## Data flow

Metrics: pods (`/metrics`) → **Prometheus** (KPS, via ServiceMonitors) → remote_write →
**Mimir**. Logs/traces/profiles: `demo app`/pods → **Alloy** (DaemonSet) → Loki/Tempo/
Pyroscope. Everything is read back through **Grafana** (provisioned datasources, reached at
`http://localhost:3000` via the NodePort mapping).

Metrics collection is described above; Alloy config lives in
[`helm/alloy/values.yaml`](../helm/alloy/values.yaml):

| Signal   | Collector | Pipeline | Destination | Endpoint |
|----------|-----------|----------|-------------|----------|
| Metrics  | Prometheus (KPS) | ServiceMonitor → scrape → `remote_write` | Mimir | `mimir-gateway/api/v1/push` |
| Logs     | Alloy | `discovery.kubernetes` → `loki.source.kubernetes` → `loki.write` | Loki | `loki:3100/loki/api/v1/push` |
| Traces   | Alloy | `otelcol.receiver.otlp` → `otelcol.processor.batch` → `otelcol.exporter.otlp` | Tempo | `tempo:4317` |
| Profiles | Alloy | `discovery.kubernetes` → `pyroscope.scrape` → `pyroscope.write` | Pyroscope | `pyroscope:4040` |

### Opt-in scraping annotations

- Metrics: no annotations — Prometheus scrapes each component through the ServiceMonitor its
  chart emits (see the metrics section above).
- Profiles: `pyroscope.io/scrape: "true"` (+ optional `pyroscope.io/port`) on the pod.
- Logs are collected for all pods automatically; traces are pushed by the app.

## Known caveats

- **Chart repos**: Grafana and Tempo are installed from the **`grafana-community`** repo
  (`grafana-community/grafana` 12.7.2, `grafana-community/tempo` 2.2.3 "single binary
  mode") because the classic `grafana/grafana` and `grafana/tempo` charts in the
  `grafana` repo are deprecated. kube-prometheus-stack comes from the
  **`prometheus-community`** repo. Mimir, Loki, Pyroscope, and Alloy still come from the
  `grafana` repo. `make repos` registers all three.
- **Log de-duplication**: `loki.source.kubernetes` tails via the Kubernetes API, so on a
  *multi-node* cluster every DaemonSet pod would tail every pod's logs. Fine for the
  single-node kind demo; enable Alloy clustering (or switch to `loki.source.file` with
  hostPath) before going multi-node.
- **No persistence for Grafana**: dashboards/datasources are provisioned as code, so the
  Grafana pod is intentionally ephemeral.
- **Demo app**: TBD. Until one is added, `make smoke-test` validates the pipeline with
  synthetic signals (a query against each read path + a pushed OTLP trace).

## Next steps / ideas

- Add a demo application that emits all four signals (e.g. an OTel-instrumented service
  with a pprof endpoint) wired to the annotations above.
- Ship curated Grafana dashboards via `grafana_dashboard=1` ConfigMaps (sidecar is enabled).
- If you later run on an environment with a routable container network (e.g. rootful
  Podman or a real cluster), a `LoadBalancer` + MetalLB setup could replace the NodePort
  mappings for a more production-like access pattern.
