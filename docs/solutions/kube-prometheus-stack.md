# Kube-Prometheus-Stack

**In one line:** the batteries-included way to run Prometheus on Kubernetes -
it bundles Prometheus, the alerting stack, and the exporters that turn a raw
cluster into a metrics-rich one.

> Chart: `prometheus-community/kube-prometheus-stack` (v87.5.1) ·
> config: [`helm/kube-prometheus-stack/values.yaml`](../../helm/kube-prometheus-stack/values.yaml) ·
> UI: Alertmanager `http://localhost:9093`

## What it is

**Prometheus** is the de-facto standard for **metrics** - numeric measurements
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
| **Prometheus Operator** | The "brain." Watches Kubernetes for `ServiceMonitor` / `PodMonitor` / `PrometheusRule` custom resources and reconfigures Prometheus automatically - no editing config files by hand. |
| **kube-state-metrics** | Exposes the *state* of Kubernetes objects as metrics (how many pods are Ready, deployment replica counts, restart counts). |
| **node-exporter** | Runs on every node and exposes *host-level* metrics (CPU, memory, disk, network). |
| **Alertmanager** | Receives alerts fired by Prometheus rules, then dedupes, groups, silences, and routes them to email/Slack/PagerDuty/etc. |

The magic glue is the **ServiceMonitor**: instead of writing scrape config, you
drop a small YAML object that says "scrape pods matching *this* label on *this*
port," and the operator wires it into Prometheus for you. Most Helm charts
(including the other tools in this demo) can emit their own ServiceMonitor, so
adding a new scrape target is declarative.

## How we use it in this demo

In this demo KPS deploys the Prometheus **Operator**, kube-state-metrics,
node-exporter, and **Alertmanager** - **not a Prometheus server**. The Operator's
job is to own the CRDs (`ServiceMonitor`/`PodMonitor`/`PrometheusRule`);
[Alloy](./alloy.md) reads them directly and does the scraping and rule-syncing.
Alertmanager is where alerts land, fired by [Mimir](./mimir.md)'s ruler.

- **The exporters light up the standard dashboards.** kube-state-metrics exposes
  the *state* of Kubernetes objects, and node-exporter exposes host metrics -
  both scraped by Alloy and remote-written to Mimir, powering the stock
  Kubernetes dashboards in Grafana out of the box.
- **Alertmanager routes every alert** through a single catch-all receiver, so
  metric alerts (from Mimir's ruler) and log alerts (from Loki's ruler) land
  together and show up in Grafana Alerting.
- **The bundled Grafana is disabled** (we run Grafana as its own release), and a
  few kind-specific scrape targets are turned off to avoid noise.

See [architecture.md](../architecture.md#metrics-collection--alerting) for the
exact values and rationale.

> Prometheus's own server can be brought into the loop instead of Alloy for
> specific testing scenarios - see [metrics-modes.md](../metrics-modes.md).

## Try it

- Open Alertmanager at `http://localhost:9093` to see the alert-routing UI.
- In Grafana, **Explore → Mimir** queries the metrics Alloy scrapes and
  remote-writes - try `up` (1 = target healthy) or
  `rate(http_server_request_duration_seconds_count[1m])`.

Once metrics land in Mimir, Grafana renders them into dashboards. The bundled
kube-state-metrics and node-exporter light up the standard Kubernetes dashboards
out of the box:

![Grafana Kubernetes / Compute Resources / Cluster dashboard showing CPU and memory utilisation panels by namespace](../images/grafana-dashboard-example.png)
*A stock **Kubernetes / Compute Resources / Cluster** dashboard in Grafana, driven by the kube-state-metrics and node-exporter metrics Alloy scrapes and remote-writes to Mimir.*

## Why it matters

Metrics are the cheapest, highest-level signal - perfect for dashboards and
alerting ("is anything on fire?"). KPS turns a bare cluster into one that
answers that question out of the box, and its operator pattern means you extend
monitoring by adding small YAML objects, never by editing a monolithic config.

## Learn more

- [Prometheus docs](https://prometheus.io/docs/)
- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator](https://prometheus-operator.dev/)
