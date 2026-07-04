# Architecture & design notes

This document records the *why* behind the setup. For usage, see the [README](../README.md).

## Goals

- **Minimal**: smallest footprint that still demonstrates all four signals end to end,
  suitable for a laptop-sized kind cluster.
- **Monolithic backends**: each backend runs as a single binary / single replica.
- **Helm-managed, values as source of truth**: every component is a Helm release with a
  local `values.yaml`; nothing is configured imperatively.
- **Two metrics-collection modes, one toggle**: by default (`METRICS_MODE=alloy`) a single
  Grafana Alloy pipeline handles **all four signals**, including metrics — it reads the
  Prometheus-Operator CRDs directly and remote-writes to Mimir, whose ruler evaluates
  alerting rules. Set `METRICS_MODE=prometheus` to fall back to the original setup, where
  kube-prometheus-stack's own Prometheus scrapes and evaluates rules instead. See
  [Metrics collection & alerting: two modes](#metrics-collection--alerting-two-modes) below.
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

## Metrics collection & alerting: two modes

Toggle with `METRICS_MODE=alloy` (default) or `METRICS_MODE=prometheus`, e.g.
`make up METRICS_MODE=prometheus`. Everything else about the demo (Loki, Tempo, Pyroscope,
Grafana panels, the otel-demo app) is identical in both modes — only how metrics get
scraped and how alerting rules get evaluated changes. Every affected chart keeps its
`values.yaml` as the `alloy`-mode default, plus a sibling `values-prometheus-metrics.yaml`
overlay that's only applied (via an extra `--values`) when `METRICS_MODE=prometheus`.

### Default: `METRICS_MODE=alloy`

kube-prometheus-stack (KPS) deploys only Alertmanager, the Prometheus operator,
kube-state-metrics, and node-exporter — **no Prometheus server**. See
[`helm/kube-prometheus-stack/values.yaml`](../helm/kube-prometheus-stack/values.yaml). The
operator stays only to own the CRDs (`ServiceMonitor`/`PodMonitor`/`PrometheusRule`); it
doesn't need its own reconcile loop running for what follows, because
[Alloy](./solutions/alloy.md) reads those CRDs directly with its own Kubernetes client (see
[`helm/alloy/values.yaml`](../helm/alloy/values.yaml)):

- `prometheus.operator.servicemonitors` / `prometheus.operator.podmonitors` discover and
  scrape every ServiceMonitor/PodMonitor in every namespace directly (no separate
  `prometheus.scrape` needed), forwarding to `prometheus.remote_write` → Mimir's gateway
  (`http://mimir-gateway.observability.svc.cluster.local/api/v1/push`).
- `mimir.rules.kubernetes` discovers every `PrometheusRule` object and syncs it into
  [Mimir](./solutions/mimir.md)'s **ruler** via the same gateway (which proxies
  `/prometheus/config/v1/rules` to the ruler component).
- Mimir's ruler (`ruler.enabled: true`, see
  [`helm/mimir/values.yaml`](../helm/mimir/values.yaml)) evaluates those rules and fires
  alerts to the KPS-deployed Alertmanager (`structuredConfig.ruler.alertmanager_url` is
  overridden to point there, since the chart's own default targets Mimir's *own* bundled
  Alertmanager, which stays disabled — there's only ever one Alertmanager in this demo).
- Grafana's Mimir datasource turns on `jsonData.manageAlerts: true` (see
  [`helm/grafana/values.yaml`](../helm/grafana/values.yaml)), so **Grafana Alerting**
  shows and manages those Mimir-evaluated rules.
- **Karma is not deployed** in this mode (dropped from `make stack`'s prerequisites) —
  Grafana Alerting plus the Alertmanager datasource already cover "what's firing right
  now," so a separate read-only Alertmanager dashboard is redundant. See
  [karma.md](./solutions/karma.md).
- No extra RBAC is needed: `grafana/alloy`'s default ClusterRole already grants
  `get`/`list`/`watch` on `servicemonitors`/`podmonitors`/`prometheusrules`
  (`monitoring.coreos.com`).

### Toggle: `METRICS_MODE=prometheus` (original as-is setup)

Restores the original architecture exactly: KPS's own Prometheus is enabled
(`prometheus.enabled: true`, full `prometheusSpec` in
[`helm/kube-prometheus-stack/values-prometheus-metrics.yaml`](../helm/kube-prometheus-stack/values-prometheus-metrics.yaml)),
scrapes every ServiceMonitor/PodMonitor in every namespace itself, evaluates
PrometheusRules itself, and remote-writes to Mimir; Mimir's ruler is disabled again
(rules are evaluated by Prometheus, not Mimir); Alloy's config reverts to
logs/traces/profiles only (no metrics section); Grafana's Mimir datasource
`manageAlerts` reverts to `false`; and **Karma** is deployed as Alertmanager's
dashboard.

- **What KPS deploys**: Prometheus, Alertmanager, the Prometheus operator,
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
Since every other chart's values (and Alloy, in the default mode) reference those CRDs,
`make stack` deploys KPS first — regardless of `METRICS_MODE`.

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
  port), [`helm/kube-prometheus-stack/values.yaml`](../helm/kube-prometheus-stack/values.yaml)
  (30090 for Prometheus, 30093 for Alertmanager), and
  [`helm/headlamp/values.yaml`](../helm/headlamp/values.yaml) (30466). The Alloy chart also
  passes `nodePort` through on `extraPorts`, but the OTLP ports are deliberately left
  unpinned — they stay cluster-internal.
- [`kind/cluster.yaml`](../kind/cluster.yaml) `extraPortMappings` publish those node ports
  on the host: `3000 -> 30000` (Grafana), `12345 -> 30345` (Alloy), `9090 -> 30090`
  (Prometheus), `9093 -> 30093` (Alertmanager), `4466 -> 30466` (Headlamp). kind wires the
  host port straight to the node container's port, and kube-proxy routes the nodePort to
  the pod.

| UI           | nodePort | Host URL |
|--------------|----------|----------|
| Grafana      | 30000    | http://localhost:3000 |
| Alloy        | 30345    | http://localhost:12345 |
| Prometheus   | 30090    | http://localhost:9090 |
| Alertmanager | 30093    | http://localhost:9093 |
| Headlamp     | 30466    | http://localhost:4466 |

`extraPortMappings` are fixed at cluster-creation time, so the port pairs in
`kind/cluster.yaml` and the chart values must stay in sync, and changing them needs a
`make down && make up`.

Karma (`METRICS_MODE=prometheus` only, 30081 -> `http://localhost:8081`) follows the
same pattern but isn't part of the always-on `make up` stack in the default
`alloy` mode, so it's left off the table above.

## Cluster UI: Headlamp

[Headlamp](https://github.com/kubernetes-sigs/headlamp) (`headlamp/headlamp`) is a
lightweight, in-cluster Kubernetes dashboard, deployed by default so the demo ships with a
point-and-click view of the cluster (pods, deployments, logs, events) alongside Grafana's
telemetry view. See [`helm/headlamp/values.yaml`](../helm/headlamp/values.yaml).

- **Runs in-cluster** (`config.inCluster: true`): Headlamp talks to the API server through
  its own ServiceAccount rather than a mounted kubeconfig.
- **No-login demo mode**: `config.unsafeUseServiceAccountToken: true` authenticates every
  visitor as the pod's ServiceAccount, so the NodePort UI opens straight in with no token
  prompt. The chart's `clusterRoleBinding` binds that ServiceAccount to **cluster-admin**.
  Together this is effectively unauthenticated cluster-admin — acceptable only because the
  kind cluster is local and throwaway; a shared deployment must swap this for OIDC or an
  auth proxy.
- **Stateless**: no persistence — it's a read/write window onto live cluster state.

## Grafana: Operator-managed via CRDs

Grafana is no longer deployed from the `grafana-community/grafana` Helm chart. It's now
fully managed by the [Grafana Operator](https://github.com/grafana/grafana-operator)
(`grafana/grafana-operator`, deployed by `make grafana-operator`): a `Grafana` custom
resource stands up the instance and `GrafanaDatasource` CRs provision each datasource —
no Helm `values.yaml` datasource blob, no imperative bootstrap script. See the
first-party chart [`helm/grafana`](../helm/grafana), whose `templates/` now just renders
CRs (plus a bit of RBAC and a ConfigMap) rather than owning a Deployment directly — the
Operator does that.

- **Everything provisioned as CRs, not files**: `templates/datasources.yaml` renders one
  `GrafanaDatasource` per entry in `values.yaml`'s `datasources` list (same fields as
  before: `uid`, `type`, `url`, `isDefault`, `jsonData` — including the Tempo/Loki/Mimir/
  Pyroscope cross-signal correlations). The Operator reconciles each straight through the
  Grafana API rather than writing a provisioning file, so `instanceSelector` — a label
  match against the `Grafana` CR (`grafana-instance: "grafana"`, see
  `templates/_helpers.tpl`) — is how each CR finds "its" Grafana instance instead of a
  file path.
- **Dashboards still arrive via the k8s-sidecar ConfigMap convention**: kube-prometheus-stack
  ships its bundled default dashboards as ConfigMaps labelled `grafana_dashboard: "1"` —
  unchanged by this migration. Since a Grafana CR's `spec.deployment` is a raw pod-spec
  *patch* (not a chart with a `sidecar.dashboards.enabled` toggle),
  [`templates/grafana.yaml`](../helm/grafana/templates/grafana.yaml) hand-adds the same
  `kiwigrid/k8s-sidecar` container the old chart used internally (same image/tag,
  `quay.io/kiwigrid/k8s-sidecar:2.8.1`), watching every namespace for that label and
  dropping matches into a `path: /var/lib/grafana/dashboards` file provider — plus a
  `ClusterRole`/`ClusterRoleBinding` (`templates/rbac-sidecar.yaml`) granting the
  Grafana pod's own ServiceAccount (`<release>-sa`, an Operator naming convention)
  permission to list/watch ConfigMaps cluster-wide.
- **Service overrides via strategic-merge patch — keyed by `port`, not `name`**:
  `spec.service.spec` merge-patches onto the Operator's default Service
  (`corev1.ServiceSpec`), which is how the NodePort/`nodePort: 30000` pin —
  needed for the `kind/cluster.yaml` `extraPortMappings` `3000 -> 30000`
  mapping, same as every other UI in this repo — survives being generated by
  the Operator instead of a chart. The list-merge key for `Service.spec.ports`
  is the Kubernetes API's own `port` field, *not* `name` — so
  [`templates/grafana.yaml`](../helm/grafana/templates/grafana.yaml)'s override
  sets `port: 3000` to match the Operator's default exactly. Get that wrong
  (e.g. pick a different port number) and the override becomes a *second*
  list entry instead of merging into the first — and since both would share
  `name: "grafana"`, the API rejects the Service outright
  (`spec.ports[1].name: Duplicate value: "grafana"`). The override also
  repeats every field of that port (`protocol`, `targetPort`), not just the
  ones being changed (`nodePort`): once a list item *is* correctly matched,
  the merge is a full field-level overwrite, not a sparse patch — any field
  the override's JSON doesn't repeat serializes as its Go zero value and
  clobbers the original (omitting `targetPort` would blank it to `0`).
- **New Service name**: the Operator names the generated Service `"<release>-service"` —
  `grafana-service`, not `grafana` — a naming convention this chart doesn't control.
  [`scripts/validate.sh`](../scripts/validate.sh) references it by that name.
- **`helm --wait` doesn't know about the Grafana CR**: it only tracks resource kinds Helm
  understands the readiness of (Deployments, Services, ...); a bare `Grafana`/
  `GrafanaDatasource` CR isn't one of them, and the Operator's own `GrafanaReady`
  condition just means "the Operator finished submitting the objects it manages" — not
  "the Grafana pod is actually up." The Makefile's `grafana` target compensates with an
  explicit `kubectl wait --for=condition=Available` against the Operator-created
  `grafana-deployment` Deployment, after first polling for it to exist (it's created
  asynchronously by the Operator's reconcile loop, not by this chart's own `helm install`).
- **No persistence**: unchanged from before — dashboards/datasources are provisioned as
  code, so the Grafana pod stays intentionally ephemeral.

## AI assistant: Grafana LLM plugin + Graft + Ollama

The demo ships an in-Grafana AI assistant that runs entirely on a local model —
no external LLM API key. It's three pieces, all deployed by `make up`: two
Grafana plugins installed by the [`helm/grafana`](../helm/grafana) chart, and
[Ollama](https://github.com/otwld/ollama-helm) (`ollama-helm/ollama`) serving
the model. See [`helm/grafana/values.yaml`](../helm/grafana/values.yaml)'s
`llm`/`graft` blocks and [`helm/ollama/values.yaml`](../helm/ollama/values.yaml).

- [**grafana-llm-app**](https://grafana.com/grafana/plugins/grafana-llm-app/) —
  Grafana's official LLM plugin, the model gateway. It's provisioned with
  `provider: custom` (OpenAI wire format, no API key required) pointed at
  Ollama's OpenAI-compatible endpoint (`http://ollama.observability.svc.cluster.local:11434`,
  the plugin appends `/v1`). Its abstract `base`/`large` model slots both map to
  `llama3.2:3b`.
- [**Graft**](https://github.com/vikshana/vikshana-graft-app)
  (`vikshana-graft-app`) — a community "AI Assistant for Grafana" app plugin
  that layers a natural-language chat UI on top of grafana-llm-app, using
  Grafana's built-in MCP tools (run in-process against the logged-in session) to
  query dashboards, metrics, logs, traces, and alerts. Find it in the Grafana
  nav at `http://localhost:3000`.
- **Ollama** — serves `llama3.2:3b` on CPU as the model backend.

How the chart wires the plugins (see
[`templates/grafana.yaml`](../helm/grafana/templates/grafana.yaml)):

- **Installed at startup via `GF_INSTALL_PLUGINS`**: the Operator's grafana
  container fetches each listed plugin before Grafana boots. grafana-llm-app is
  a plain catalog id; Graft is **not in the catalog**, so it's installed from a
  release-zip URL in `<url>;<plugin-id>` form. Graft is also **unsigned**, so
  its id is added to `allow_loading_unsigned_plugins` in the `Grafana` CR config
  — Grafana refuses to load unsigned plugins otherwise.
- **Configured via file-based plugin provisioning**: a ConfigMap
  (`grafana-plugins-provisioning`) is mounted at
  `/etc/grafana/provisioning/plugins` — the same ConfigMap mechanism the chart
  uses for dashboards. It holds the LLM plugin's provider config and a stanza
  that enables the Graft app by default. Both plugin blocks are gated on their
  `enabled` values, so setting `llm.enabled: false` / `graft.enabled: false`
  cleanly drops the env entries, the unsigned allow-list, and the provisioning.
- **Graft is pinned to v0.2.0**: upstream's build/publish workflow only fires on
  legacy `v*` tags, but releases are now tagged `graft-v*`, so v0.2.0 is the
  newest tag that actually ships a prebuilt zip (the v0.3.0–v0.6.x sources have
  no downloadable artifact). Bump `graft.pluginUrl` if upstream publishes newer
  builds again.

On Ollama itself:

- **Part of `make up`, but the heaviest component**: Ollama wants multiple CPUs
  and several GiB of RAM for CPU-only `llama3.2:3b` inference (see
  `helm/ollama/values.yaml`'s `resources`), so responses are still slow. It's
  folded into `make up` because Graft has no backend without it.
- **Why 3b (not a bigger model)**: `grafana-llm-app` hardcodes a 2-minute HTTP
  timeout on its call to Ollama. On CPU an 8B model generates ~2-3 tok/s, so a
  real Graft turn overruns that timeout and fails; `llama3.2:3b` runs ~2.4x
  faster and stays inside it. `OLLAMA_KEEP_ALIVE=24h` keeps the model resident
  so idle unloads don't add a cold-reload penalty.
- **Local model, no API key**: nothing points at a hosted provider, so no
  `OPENAI_API_KEY`-style secret exists anywhere in this demo.
- **No persistence**: like the rest of this demo, storage is ephemeral.
  `llama3.2:3b` (~2GB) is re-pulled by a postStart hook on every pod start; a
  PVC wouldn't survive `make down` anyway on this kind/Podman setup. Kubernetes
  doesn't mark the container `Running` until that hook completes, so
  `OLLAMA_TIMEOUT` (default `20m`, see the Makefile) gives `helm --wait` much
  more room than the default `HELM_TIMEOUT`.

Separately, Alloy's OTLP receiver also forwards **logs** (not just traces) to
Loki — any in-cluster workload that emits logs over OTLP (rather than only
stdout) lands there. [`helm/alloy/values.yaml`](../helm/alloy/values.yaml) (and
its `values-prometheus-metrics.yaml` twin) wires a `logs` output ->
`otelcol.processor.attributes` (tags `service.name`/`service.namespace` as
`loki.resource.labels` hints — `otelcol.exporter.loki` doesn't promote OTLP
attributes to Loki labels on its own) -> `otelcol.exporter.loki` -> the same
`loki.write` receiver pod-tailed logs already use.

## Data flow

Default (`METRICS_MODE=alloy`): pods (`/metrics`) → **Alloy** (via ServiceMonitors/
PodMonitors) → remote_write → **Mimir**. Toggle (`METRICS_MODE=prometheus`): pods →
**Prometheus** (KPS, via ServiceMonitors) → remote_write → **Mimir**. Logs/traces/profiles,
in both modes: `demo app`/pods → **Alloy** (DaemonSet) → Loki/Tempo/Pyroscope. Everything is
read back through **Grafana** (provisioned datasources, reached at `http://localhost:3000`
via the NodePort mapping).

Metrics collection is described above; Alloy config lives in
[`helm/alloy/values.yaml`](../helm/alloy/values.yaml):

| Signal   | Collector | Pipeline | Destination | Endpoint |
|----------|-----------|----------|-------------|----------|
| Metrics  | Alloy (default) | `prometheus.operator.servicemonitors`/`podmonitors` → `prometheus.remote_write` | Mimir | `mimir-gateway/api/v1/push` |
| Metrics  | Prometheus, KPS (`METRICS_MODE=prometheus`) | ServiceMonitor → scrape → `remote_write` | Mimir | `mimir-gateway/api/v1/push` |
| Rules    | Alloy (default) | `mimir.rules.kubernetes` (PrometheusRule CRDs) | Mimir ruler | `mimir-gateway/prometheus/config/v1/rules` |
| Logs     | Alloy | `discovery.kubernetes` → `loki.source.kubernetes` → `loki.write` | Loki | `loki:3100/loki/api/v1/push` |
| Logs (OTLP) | Alloy | `otelcol.receiver.otlp` → `otelcol.processor.attributes` → `otelcol.exporter.loki` → `loki.write` | Loki | `loki:3100/loki/api/v1/push` |
| Traces   | Alloy | `otelcol.receiver.otlp` → `otelcol.processor.batch` → `otelcol.exporter.otlp` | Tempo | `tempo:4317` |
| Profiles | Alloy | `discovery.kubernetes` → `pyroscope.scrape` → `pyroscope.write` | Pyroscope | `pyroscope:4040` |

### Opt-in scraping annotations

- Metrics: no annotations — the collector (Alloy or Prometheus, depending on
  `METRICS_MODE`) scrapes each component through the ServiceMonitor its chart emits (see
  the metrics section above).
- Profiles: `pyroscope.io/scrape: "true"` (+ optional `pyroscope.io/port`) on the pod.
- Logs are collected for all pods automatically; traces are pushed by the app.

## Known caveats

- **Chart repos**: Tempo is installed from the **`grafana-community`** repo
  (`grafana-community/tempo` 2.2.3, "single binary mode") because the classic
  `grafana/tempo` chart in the `grafana` repo is deprecated. Grafana itself is no longer
  a Helm chart at all — see [Grafana: Operator-managed via CRDs](#grafana-operator-managed-via-crds)
  below. kube-prometheus-stack comes from the **`prometheus-community`** repo. Mimir,
  Loki, Pyroscope, Alloy, and the Grafana Operator still come from the `grafana` repo.
  `make repos` registers all of these (Ollama's `ollama-helm` repo too).
- **Log de-duplication**: `loki.source.kubernetes` tails via the Kubernetes API, so on a
  *multi-node* cluster every DaemonSet pod would tail every pod's logs. Fine for the
  single-node kind demo; enable Alloy clustering (or switch to `loki.source.file` with
  hostPath) before going multi-node.
- **No persistence for Grafana**: dashboards/datasources are provisioned as code, so the
  Grafana pod is intentionally ephemeral.

## Demo application (apps/otel-demo)

An OTel-instrumented Go microservices app (`frontend → {checkout → payment,
catalog}`) lives in [`apps/otel-demo/`](../apps/otel-demo/) in its own **`otel-demo`**
namespace. The frontend serves an interactive web UI at `http://localhost:8080` for
driving traffic by hand; an optional `loadgen` (off by default, enable with
`DEMO_LOADGEN=true`) drives it in the background. It's deliberately designed to feed the *existing* collectors with
**zero changes to any `helm/*/values.yaml`**:

| Signal   | App emits | Stack path |
|----------|-----------|-----------|
| Traces   | OTel SDK, OTLP/gRPC to Alloy (`OTEL_EXPORTER_OTLP_ENDPOINT`) | Alloy `otelcol.receiver.otlp` → Tempo |
| Metrics  | OTel Prometheus exporter on `/metrics` + a `PodMonitor` | Alloy scrape (default) or Prometheus scrape (`METRICS_MODE=prometheus`) → remote_write → Mimir |
| Rules    | `PrometheusRule` (`apps/otel-demo/k8s/prometheusrules.yaml`) | Synced by Alloy into Mimir's ruler (default) or evaluated by Prometheus directly (`METRICS_MODE=prometheus`) |
| Logs     | `slog` JSON to stdout with a `trace_id` field | Alloy pod-log tail → Loki |
| Profiles | Go `net/http/pprof` + `pyroscope.io/scrape: "true"` | Alloy `pyroscope.scrape` → Pyroscope |

Two constraints the app respects so the stack stays untouched:

- **Log field spelling**: the trace id is logged as `trace_id` to match the Loki datasource
  `derivedFields` regex in `helm/grafana/values.yaml` (and the structured-metadata key Alloy
  promotes), so logs auto-link to traces.
- **Single container port**: each service serves app routes, `/metrics`, and
  `/debug/pprof/*` on one port, so Alloy's `discovery.kubernetes` (which infers the scrape
  address from the declared container port) resolves exactly one Pyroscope target per pod.
  (If a service ever needed multiple ports, the alternative is a small relabel in Alloy to
  honour a `pyroscope.io/port` annotation.)

Build/deploy/verify: `make demo` (add `DEMO_LOADGEN=true` to also run the loadgen),
`make demo-ui`, `make demo-test`, `make demo-clean`. A curated RED
dashboard ships as a `grafana_dashboard=1` ConfigMap and is auto-loaded by the sidecar.
