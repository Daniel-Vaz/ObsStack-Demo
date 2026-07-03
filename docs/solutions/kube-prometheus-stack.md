# Kube-Prometheus-Stack

**In one line:** the batteries-included way to run Prometheus on Kubernetes —
it bundles Prometheus, the alerting stack, and the exporters that turn a raw
cluster into a metrics-rich one.

> Chart: `prometheus-community/kube-prometheus-stack` (v87.5.1) ·
> config: [`helm/kube-prometheus-stack/values.yaml`](../../helm/kube-prometheus-stack/values.yaml) ·
> UIs: Prometheus `http://localhost:9090`, Alertmanager `http://localhost:9093`

## What it is

**Prometheus** is the de-facto standard for **metrics** — numeric measurements
sampled over time (request rate, memory usage, queue depth). It works by
**pulling** ("scraping") a `/metrics` HTTP endpoint from each target on a
schedule and storing the samples in a time-series database you query with
**PromQL**.

Kube-Prometheus-Stack (**KPS**) is not one thing but a curated *bundle* that
gets you a production-shaped Prometheus setup in a single Helm install. It's the
easiest on-ramp to metrics on Kubernetes.

## The nested components

Installing KPS gives you several cooperating pieces:

| Component | What it does |
|-----------|--------------|
| **Prometheus** | Scrapes targets, stores time-series, answers PromQL queries. |
| **Prometheus Operator** | The "brain." Watches Kubernetes for `ServiceMonitor` / `PodMonitor` / `PrometheusRule` custom resources and reconfigures Prometheus automatically — no editing config files by hand. |
| **kube-state-metrics** | Exposes the *state* of Kubernetes objects as metrics (how many pods are Ready, deployment replica counts, restart counts). |
| **node-exporter** | Runs on every node and exposes *host-level* metrics (CPU, memory, disk, network). |
| **Alertmanager** | Receives alerts fired by Prometheus rules, then dedupes, groups, silences, and routes them to email/Slack/PagerDuty/etc. |

The magic glue is the **ServiceMonitor**: instead of writing scrape config, you
drop a small YAML object that says "scrape pods matching *this* label on *this*
port," and the operator wires it into Prometheus for you. Most Helm charts
(including the other tools in this demo) can emit their own ServiceMonitor, so
adding a new scrape target is declarative.

## How we use it in this demo

KPS owns **one signal: metrics.** (Logs, traces, and profiles go through
[Alloy](./alloy.md) instead.)

- Prometheus discovers every component via the **ServiceMonitors** each chart
  emits, plus the demo app's `PodMonitor`.
- It keeps only a short **2-hour local buffer**, then **remote-writes** all
  samples to [Mimir](./mimir.md) for long-term storage. Grafana reads metrics
  from Mimir, not from Prometheus directly.
- The bundled Grafana is **disabled** (we run Grafana as its own release), and a
  few kind-specific scrape targets are turned off to avoid noise.

See [architecture.md](../architecture.md#metrics-collection-kube-prometheus-stack)
for the exact values and rationale.

## Try it

- Open Prometheus at `http://localhost:9090` → **Status → Targets** to watch it
  discover and scrape every component.
- Run a PromQL query like `up` (1 = target healthy) or
  `rate(http_server_request_duration_seconds_count[1m])`.
- Open Alertmanager at `http://localhost:9093` to see the alert-routing UI.
- In Grafana, **Explore → Mimir** queries the *same* metrics after remote-write.

![Prometheus query UI at localhost:9090 graphing an apiserver burn-rate PromQL expression](../images/prometheus-ui.png)
*Prometheus's own UI at `http://localhost:9090` — the short 2-hour local buffer, queryable with PromQL before samples are remote-written to Mimir.*

Once metrics land in Mimir, Grafana renders them into dashboards. The bundled
kube-state-metrics and node-exporter light up the standard Kubernetes dashboards
out of the box:

![Grafana Kubernetes / Compute Resources / Cluster dashboard showing CPU and memory utilisation panels by namespace](../images/grafana-dashboard-example.png)
*A stock **Kubernetes / Compute Resources / Cluster** dashboard in Grafana, driven by the metrics KPS scrapes and remote-writes to Mimir.*

## Why it matters

Metrics are the cheapest, highest-level signal — perfect for dashboards and
alerting ("is anything on fire?"). KPS turns a bare cluster into one that
answers that question out of the box, and its operator pattern means you extend
monitoring by adding small YAML objects, never by editing a monolithic config.

## Learn more

- [Prometheus docs](https://prometheus.io/docs/)
- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator](https://prometheus-operator.dev/)
