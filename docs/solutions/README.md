# Solution guides

Short, beginner-friendly introductions to each tool in this demo — what it is,
what it's for, and how it's wired into this stack. Read these if you're new to
the Grafana observability ecosystem and want the "why does this exist" before
the "how is it configured" (which lives in [architecture.md](../architecture.md)).

## The stack at a glance

Every tool here does **one job well** and hands off to the next. Together they
cover the [four signals of observability](../otel-instrumentation.md) — metrics,
logs, traces, profiles — plus the plumbing to collect, store, and view them.

| Guide | Role | One-liner |
|-------|------|-----------|
| [Kube-Prometheus-Stack](./kube-prometheus-stack.md) | Metrics collection | Prometheus + operator + exporters; scrapes metrics and remote-writes to Mimir |
| [Mimir](./mimir.md) | Metrics storage | Horizontally scalable, long-term store for Prometheus metrics |
| [Loki](./loki.md) | Logs storage | "Prometheus for logs" — indexes labels, not full text |
| [Tempo](./tempo.md) | Traces storage | Cheap, high-scale distributed tracing backend |
| [Pyroscope](./pyroscope.md) | Profiles storage | Continuous profiling — flame graphs over time |
| [Alloy](./alloy.md) | Collection pipeline | One agent that collects logs, traces, and profiles |
| [Karma](./karma.md) | Alert dashboard | Read-only UI over Alertmanager — every alert in one groupable view |
| [Headlamp](./headlamp.md) | Cluster UI | Point-and-click Kubernetes dashboard |
| [Kind & Podman](./kind-and-podman.md) | Local platform | A throwaway Kubernetes cluster on your laptop |

Grafana itself isn't covered separately — it's the **single pane of glass** that
queries all of the datasources above. Everything you store in Mimir, Loki, Tempo,
and Pyroscope is explored through Grafana at `http://localhost:3000`.

## How they fit together

```
  apps + pods                 collectors                   stores            view
  ───────────                 ──────────                   ──────            ────
  /metrics      ──scrape──▶  Prometheus (KPS) ──remote_write──▶  Mimir    ─┐
  logs (stdout) ──tail────▶                                      Loki      ─┤
  traces (OTLP) ──receive─▶  Alloy            ──────────────────▶ Tempo    ─┼─▶ Grafana
  profiles      ──scrape──▶                                      Pyroscope  ┘

  the cluster itself ─────────────────────────────────────────────────▶ Headlamp
```

Read them in table order, or jump straight to whichever tool you're curious about.
