# Solution guides

Short, beginner-friendly introductions to each tool in this demo — what it is,
what it's for, and how it's wired into this stack. Read these if you're new to
the Grafana observability ecosystem and want the "why does this exist" before
the "how is it configured" (which lives in [architecture.md](../architecture.md)).

> [!NOTE]
> Metrics collection has two toggleable modes (`METRICS_MODE=alloy`, the
> default, or `METRICS_MODE=prometheus`) — see
> [architecture.md](../architecture.md#metrics-collection--alerting-two-modes).
> Below reflects the default; [Alloy](./alloy.md), [Mimir](./mimir.md),
> [Kube-Prometheus-Stack](./kube-prometheus-stack.md), and [Karma](./karma.md)
> each call out how their role changes in the toggle.

## The stack at a glance

Every tool here does **one job well** and hands off to the next. Together they
cover the [four signals of observability](../otel-instrumentation.md) — metrics,
logs, traces, profiles — plus the plumbing to collect, store, and view them.

| Guide | Role | One-liner |
|-------|------|-----------|
| [Kube-Prometheus-Stack](./kube-prometheus-stack.md) | Operator, exporters, Alertmanager | Operator + kube-state-metrics + node-exporter + Alertmanager (+ Prometheus itself in the `METRICS_MODE=prometheus` toggle) |
| [Mimir](./mimir.md) | Metrics storage + rule evaluation | Horizontally scalable, long-term store for Prometheus metrics; ruler evaluates alerting rules by default |
| [Loki](./loki.md) | Logs storage | "Prometheus for logs" — indexes labels, not full text |
| [Tempo](./tempo.md) | Traces storage | Cheap, high-scale distributed tracing backend |
| [Pyroscope](./pyroscope.md) | Profiles storage | Continuous profiling — flame graphs over time |
| [Alloy](./alloy.md) | Collection pipeline | One agent that collects logs, traces, profiles, *and metrics* by default |
| [Karma](./karma.md) | Alert dashboard (legacy toggle only) | Read-only UI over Alertmanager — every alert in one groupable view |
| [Headlamp](./headlamp.md) | Cluster UI | Point-and-click Kubernetes dashboard |
| [Ollama](./ollama.md) | Local LLM inference | Runs `llama3.2:3b` locally — the model backend for Grafana's Graft AI assistant, no external AI API key needed |
| [Kind & Podman](./kind-and-podman.md) | Local platform | A throwaway Kubernetes cluster on your laptop |

Grafana itself isn't covered separately — it's the **single pane of glass** that
queries all of the datasources above. Everything you store in Mimir, Loki, Tempo,
and Pyroscope is explored through Grafana at `http://localhost:3000`.

## How they fit together

Default (`METRICS_MODE=alloy`):

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

Toggle (`METRICS_MODE=prometheus`, the original setup):

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
