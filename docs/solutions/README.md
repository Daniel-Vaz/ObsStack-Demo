# Solution guides

Short, beginner-friendly introductions to each tool in this demo - what it is,
what it's for, and how it's wired into this stack. Read these if you're new to
the Grafana observability ecosystem and want the "why does this exist" before
the "how is it configured" (which lives in [architecture.md](../architecture.md)).

## The stack at a glance

Every tool here does **one job well** and hands off to the next. Together they
cover the [four signals of observability](../otel-instrumentation.md) - metrics,
logs, traces, profiles - plus the plumbing to collect, store, and view them.

| Guide | Role | One-liner |
|-------|------|-----------|
| [Kube-Prometheus-Stack](./kube-prometheus-stack.md) | Operator, exporters, Alertmanager | Prometheus Operator + kube-state-metrics + node-exporter + Alertmanager |
| [Mimir](./mimir.md) | Metrics storage + rule evaluation | Horizontally scalable, long-term store for Prometheus metrics; ruler evaluates alerting rules |
| [Loki](./loki.md) | Logs storage | "Prometheus for logs" - indexes labels, not full text |
| [Tempo](./tempo.md) | Traces storage | Cheap, high-scale distributed tracing backend |
| [Pyroscope](./pyroscope.md) | Profiles storage | Continuous profiling - flame graphs over time |
| [Alloy](./alloy.md) | Collection pipeline | One agent that collects metrics, logs, traces, *and* profiles |
| [Headlamp](./headlamp.md) | Cluster UI | Point-and-click Kubernetes dashboard |
| [Kind & Podman](./kind-and-podman.md) | Local platform | A throwaway Kubernetes cluster on your laptop |

Grafana itself isn't covered separately - it's the **single pane of glass** that
queries all of the datasources above. Everything you store in Mimir, Loki, Tempo,
and Pyroscope is explored through Grafana at `http://localhost:3000`.

## How they fit together

```
  apps + pods                 collector              stores                view
  ───────────                 ─────────              ──────                ────
  /metrics, rules ──scrape/sync──▶
  logs            ──tail─────────▶   Alloy  ──▶  Mimir · Loki · Tempo ──▶ Grafana
  traces          ──receive──────▶                    Pyroscope
  profiles        ──scrape───────▶

  Mimir's ruler ──alerts──▶ Alertmanager (surfaced in Grafana Alerting)

  the cluster itself ─────────────────────────────────────────────▶ Headlamp
```

Read them in table order, or jump straight to whichever tool you're curious about.

> An alternate metrics-collection mode for specific testing scenarios - running
> kube-prometheus-stack's own Prometheus server, with [Karma](./karma.md) as an
> Alertmanager dashboard - is documented in [metrics-modes.md](../metrics-modes.md).
>
> An alternate, key-less model backend for Grafana's Graft AI assistant -
> running [Ollama](./ollama.md) in-cluster instead of Azure AI Foundry - is
> documented in [llm-backends.md](../llm-backends.md).
>
> An alternate dashboard backend for specific testing scenarios - running
> [Perses](./perses.md) instead of Grafana - is documented in
> [dashboard-backends.md](../dashboard-backends.md).
