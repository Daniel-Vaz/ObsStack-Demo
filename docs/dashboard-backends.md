# Dashboard backend: the Perses testing mode

> **This is an advanced, opt-in option for specific testing scenarios.**
> The default setup visualizes everything through Grafana, and every other
> document in this repo describes that default. Reach for the mode below only
> when you specifically want to run [Perses](https://perses.dev/) instead.

## The default (no flag needed)

`make up` deploys **Grafana** (Operator-managed, via `helm/grafana`) as the
single pane of glass over Mimir/Loki/Tempo/Pyroscope, plus the `grafana-llm-app`
and Graft AI plugins, plus kube-prometheus-stack's bundled default dashboards
(force-deployed as ConfigMaps and picked up by Grafana's k8s-sidecar). See
[architecture.md](architecture.md) for the full design.

## The `DASHBOARD_BACKEND=perses` testing mode

Set `DASHBOARD_BACKEND=perses` to swap Grafana out for
[Perses](solutions/perses.md) - a CNCF sandbox dashboarding tool that
speaks Prometheus/Loki/Tempo/Pyroscope natively - instead. This is useful when
you want to see a Grafana alternative running against this stack's real
infrastructure: open licensing, dashboards-as-code, or evaluating a lighter
footprint.

```bash
make up DASHBOARD_BACKEND=perses     # bring the whole stack up in this mode
```

`DASHBOARD_BACKEND` also applies to `make stack` and the individual
`make perses-operator` / `perses` / `kube-prometheus-stack` targets, and
`make validate`.

Everything else about the demo - Mimir, Loki, Tempo, Pyroscope, Alloy, the
otel-demo app, metrics/logs/traces/profiles collection - is identical to the
default. Only **what renders the dashboards** changes, and - because Perses
has no AI-assistant plugin in this demo - the **AI assistant disappears
entirely** in this mode, rather than switching backends the way
`LLM_BACKEND=ollama` does.

### What changes

| | Default (Grafana) | `DASHBOARD_BACKEND=perses` |
|---|---|---|
| Visualization | Grafana (Operator-managed) | Perses (Operator-managed) |
| Dashboards | kube-prometheus-stack's bundled defaults, force-deployed as ConfigMaps | [perses/community-mixins](https://github.com/perses/community-mixins), vendored as `PersesDashboard` CRs |
| Datasources | 5 `GrafanaDatasource` CRs (Mimir/Loki/Tempo/Pyroscope/Alertmanager) | 4 `PersesGlobalDatasource` CRs (Mimir/Loki/Tempo/Pyroscope) |
| AI assistant | grafana-llm-app + Graft (Azure AI Foundry or Ollama) | none |
| Ollama | deployed only if `LLM_BACKEND=ollama` | never deployed |
| kube-prometheus-stack | `grafana.forceDeployDashboards: true` | `grafana.forceDeployDashboards: false` (nothing would consume those ConfigMaps) |
| Extra UI | Grafana `http://localhost:3000` | Perses `http://localhost:8082` |

Under the hood, every affected chart keeps its default `values.yaml` for the
Grafana setup, plus overlays/new charts applied only when
`DASHBOARD_BACKEND=perses`:

- [`helm/kube-prometheus-stack/values-perses-dashboards.yaml`](../helm/kube-prometheus-stack/values-perses-dashboards.yaml)
  turns off `forceDeployDashboards`.
- [`helm/perses-operator`](../helm/perses-operator) and
  [`helm/perses`](../helm/perses) (the Perses-side analogues of
  `helm/grafana-operator`/`helm/grafana`) deploy in place of them - see
  [architecture.md](architecture.md) and [solutions/perses.md](solutions/perses.md)
  for how the Operator/CRD model and the vendored dashboards work.
- `make up` skips `ollama` regardless of `LLM_BACKEND`, since Perses has
  nothing to point a model backend at in this demo.

With Perses in the loop you get its own UI at `http://localhost:8082`, no
login required, browsing the vendored dashboards under the `observability`
project.

### Switching between modes

Unlike [`METRICS_MODE`](metrics-modes.md) and [`LLM_BACKEND`](llm-backends.md),
which are values-overlays applied to the *same* Helm release, Grafana and
Perses are two **entirely separate releases** (`grafana`+`grafana-operator` vs.
`perses`+`perses-operator`). Re-running `make up` with a different
`DASHBOARD_BACKEND` on a cluster that's already up **layers one on top of the
other** instead of replacing it - run `make clean` first (or a fresh
`make down && make up`) to switch cleanly.

kind's `extraPortMappings` are static, so the Perses (`8082`) host port is
always mapped - it simply sits idle in the default mode with nothing
listening.
