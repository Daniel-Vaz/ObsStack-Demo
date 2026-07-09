# Perses

**In one line:** a CNCF dashboarding tool — an open, dashboard-as-code
alternative to Grafana, with the same Mimir/Loki/Tempo/Pyroscope datasources
underneath.

> Chart: `perses/perses-operator` (0.4.0) + first-party `helm/perses` (CRDs) ·
> config: [`helm/perses/values.yaml`](../../helm/perses/values.yaml) ·
> UI: `http://localhost:8082`

> [!NOTE]
> **Opt-in, not deployed by default.** This demo ships Grafana as the
> visualization layer; Perses is an alternate dashboard backend for testing
> scenarios. Deploy it with `make up DASHBOARD_BACKEND=perses` — see
> [dashboard-backends.md](../dashboard-backends.md). In this mode Grafana, the
> Grafana Operator, and everything LLM/Graft/Ollama-related are skipped
> entirely — Perses has no AI-assistant plugin in this demo.

## What it is

[**Perses**](https://github.com/perses/perses) is a CNCF sandbox
visualization tool, built by (mostly) the same community behind Prometheus and
Thanos, with dashboards-as-code and GitOps as first-class concerns rather than
an afterthought: a dashboard is a plain YAML/JSON resource with a versioned
schema, not an opaque JSON blob exported from a UI. It speaks Prometheus, Loki,
Tempo, and Pyroscope natively — the same four backends this demo already runs.

## Where it fits among the others

Perses occupies exactly the slot Grafana does in the default setup: the
**single pane of glass** that queries Mimir/Loki/Tempo/Pyroscope and renders
dashboards. Nothing about collection or storage changes — only the
query/render layer at the top.

```
  Mimir · Loki · Tempo · Pyroscope  ──datasources──▶  Perses  ──▶  you
```

## How we use it in this demo

Perses is deployed the same way Grafana is: an Operator that reconciles CRDs
into a running instance, rather than a values-driven Helm chart directly.

- **Operator-managed via CRDs**, mirroring Grafana's setup
  (see [architecture.md](../architecture.md)): the
  [Perses Operator](https://github.com/perses/perses-operator)
  (`helm/perses-operator`) reconciles a `Perses` instance CR, four
  `PersesGlobalDatasource` CRs (Mimir/Loki/Tempo/Pyroscope, same in-cluster
  URLs Grafana uses), and every vendored dashboard CR — all defined in
  [`helm/perses`](../../helm/perses).
- **No cert-manager dependency.** The operator's webhook (used for CRD version
  conversion) normally needs cert-manager to issue its TLS cert;
  `certManager.enable: false` (see
  [`helm/perses-operator/values.yaml`](../../helm/perses-operator/values.yaml))
  falls back to a self-signed cert generated at install time instead — no new
  cluster-wide dependency for a local demo.
- **Dashboards from [`perses/community-mixins`](https://github.com/perses/community-mixins).**
  Every dashboard under that repo's `examples/dashboards/operator/` tree (11
  mixins — Kubernetes, node-exporter, Alertmanager, Prometheus, and more) is
  vendored into [`helm/perses/templates/dashboards/`](../../helm/perses/templates/dashboards/)
  by [`scripts/vendor-perses-dashboards.py`](../../scripts/vendor-perses-dashboards.py),
  rewritten from upstream's v1alpha1 shape to v1alpha2 (see that script's
  docstring for why the rewrite is needed).
- **NodePort via a hand-rolled Service.** The `Perses` CR's own
  `spec.service` only supports a name/annotations override, not
  `type`/`nodePort`, so [`helm/perses/templates/perses.yaml`](../../helm/perses/templates/perses.yaml)
  adds a second Service (`perses-nodeport`) alongside the Operator's own —
  the Perses-side analogue of the Grafana Operator Service quirk documented
  in [architecture.md](../architecture.md).

## Try it

Open `http://localhost:8082` — no login. Browse the **`observability`**
project (Perses maps the Kubernetes namespace 1:1 to a project) for the
vendored dashboards, e.g. **Kubernetes / Compute Resources / Cluster** or
**Node Exporter / Nodes**, rendering from the same Mimir data Grafana would.

## Why it matters

Grafana isn't the only option for a Prometheus-shaped observability stack, and
teams evaluating alternatives — open licensing, dashboards-as-code, or just a
lighter footprint — want to see one running against real infrastructure, not
just read about it. `make up DASHBOARD_BACKEND=perses` gets a fully wired
Perses instance, with real dashboards showing real cluster data, with one flag.

## Learn more

- [Perses on GitHub](https://github.com/perses/perses)
- [Perses Operator](https://github.com/perses/perses-operator)
- [perses/community-mixins](https://github.com/perses/community-mixins) — the dashboards this demo vendors
- [Perses docs](https://perses.dev/)
