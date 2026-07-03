# kagent

**In one line:** a Kubernetes-native AI agent framework running **ObsAgent**,
a Kubernetes observability expert agent that can query this stack's own live
telemetry and act on what it finds, entirely on a local model.

> Charts: `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds` +
> `oci://ghcr.io/kagent-dev/kagent/helm/kagent` (0.9.11) ·
> config: [`helm/kagent/values.yaml`](../../helm/kagent/values.yaml),
> [`helm/kagent/obs-agent.yaml`](../../helm/kagent/obs-agent.yaml) ·
> UI: `make kagent-ui` → `http://localhost:8090`

> [!NOTE]
> **Optional, not part of `make up`.** Deploy it with `make ai` (which also
> deploys [Ollama](./ollama.md)) — even at this stage it's the heaviest
> thing in the repo, so it's opt-in rather than always-on.

## What it is

[**kagent**](https://github.com/kagent-dev/kagent) runs AI agents as
Kubernetes custom resources. An `Agent` CRD bundles a system prompt, a set of
tools, and an LLM configuration (`ModelConfig`); the kagent controller turns
that into a running agent you can chat with via a web UI or the A2A protocol.
Agents call **tools** rather than answering from training data alone — tools
can read and modify real cluster state, query real telemetry, and so on,
depending on what's wired up.

## The point of it in this demo

The goal isn't "a chatbot in the cluster" — it's **ObsAgent**, a Kubernetes
observability AI agent expert: one agent that can query this stack's own
live telemetry (Mimir metrics, Loki logs, Tempo traces, Pyroscope profiles —
all through Grafana — plus the cluster itself) and take action on what it
finds, the way an experienced on-call engineer would. ObsAgent is a **custom
`Agent` CRD** — [`helm/kagent/obs-agent.yaml`](../../helm/kagent/obs-agent.yaml)
— applied alongside this chart rather than one of the ~10 stock agents the
upstream chart ships (see "No stock agents — ObsAgent instead" below).

```
  you (browser)  ──chat──▶  kagent UI  ──▶  controller  ──▶  ObsAgent
                                                  │                   │
                                          ModelConfig            its tools
                                                  │                   │         ┌──▶  this cluster (k8s_*, helm_*)
                                                  ▼                   └─────────┤
                                               Ollama                           └──▶  grafana-mcp (all tools) ──▶ this
                                          (llama3.1:8b)                              Grafana/Mimir/Loki/Tempo/Pyroscope
                                                                                 └──▶  prometheus_* (kagent-tools) ──▶ Mimir

  kagent + kagent-tools + grafana-mcp + ObsAgent  ──OTLP traces/logs──▶  Alloy  ──▶  Tempo / Loki
```

## How we use it in this demo

kagent is deployed by `make kagent` (after `make kagent-crds`, `make ollama`,
and `make grafana` — see the Makefile's `ai` target group, which `make up`
does **not** run) into the `observability` namespace.

- **No stock agents — ObsAgent instead.** The upstream chart ships ~10
  optional built-in agents (k8s, kgateway, Istio, Argo Rollouts, Cilium,
  Helm, PromQL, and general observability) — each its own always-on
  Deployment. [`helm/kagent/values.yaml`](../../helm/kagent/values.yaml)
  disables all of them, including the two stock agents closest to
  ObsAgent's job (`k8s-agent`, a generic troubleshooting agent;
  `observability-agent`, which queries Grafana/Mimir) — this demo spends
  that pod budget on one purpose-built agent instead of several overlapping
  stock ones. [`helm/kagent/obs-agent.yaml`](../../helm/kagent/obs-agent.yaml)
  defines ObsAgent as a raw `Agent` CRD manifest (applied by the Makefile's
  `kagent` target right after the Helm install — the chart itself is
  OCI-sourced, with nowhere local to template a custom agent into it). Its
  tools: `k8s_*`, `helm_*`, `prometheus_*`, and `datetime_get_current_time`
  from kagent's own built-in tool server, plus **every** tool `grafana-mcp`
  exposes (dashboards, Prometheus/Mimir, Loki, Pyroscope, alerting,
  incidents, on-call, Sift investigations, and more — see the manifest's
  header comment for why `toolNames` is *omitted* rather than listing all
  ~65 of them: the `Agent` CRD caps `toolNames` at 50 entries, and an
  omitted/empty filter is kagent's own documented way to mean "all tools").
- **No API key — talks to [Ollama](./ollama.md).** `providers.default: ollama`
  points kagent's default `ModelConfig` at
  `ollama.observability.svc.cluster.local:11434`, serving `llama3.1:8b`. The
  chart's own default context window (`num_ctx: 64000`, sized for a
  different model) is explicitly overridden down to `4096` — at 64K tokens
  of KV-cache, CPU-only inference would blow past Ollama's memory limit.
- **`grafana-mcp` is ObsAgent's main tool server.** Read/query/manage access
  to Grafana dashboards, datasources, alerting, and — through Grafana's own
  datasources — Mimir, Loki, and Pyroscope. It authenticates with a Grafana
  service-account token provisioned entirely declaratively: a
  `GrafanaServiceAccount` CR in [`helm/grafana`](../../helm/grafana) has the
  Grafana Operator create the service account, generate a token, and write
  it to a Secret — no manual step. See
  [architecture.md](../architecture.md#grafana-operator-managed-via-crds)
  for why that Secret's token key needed a small adapter
  (`GRAFANA_SERVICE_ACCOUNT_TOKEN_FILE`) rather than a direct `secretRef`.
  You can also point any MCP client at it directly
  (`kagent-grafana-mcp.observability.svc.cluster.local:8000`), independent
  of ObsAgent.
- **OTel tracing + logging into this stack's own Alloy.** `otel.tracing` and
  `otel.logging` are both enabled and point at
  `alloy.observability.svc.cluster.local:4317` — the same OTLP endpoint
  address the otel-demo app pushes to. Traces need nothing extra on Alloy's
  side (its OTLP receiver already forwards to Tempo); logs needed a small
  addition — see [architecture.md](../architecture.md#ai-agent-kagent--ollama)
  for the `otelcol.exporter.loki` bridge added to
  [`helm/alloy/values.yaml`](../../helm/alloy/values.yaml). `kagent-tools`
  (the MCP tool server kagent ships built in) has its *own* separate `otel`
  block in the chart and needs the same endpoint set independently — also
  done in our values file.
- **NodePort via a supplementary Service.** kagent's own UI Service template
  doesn't support a pinned `nodePort` the way this repo's other charts do —
  so [`helm/kagent/kagent-ui-nodeport.yaml`](../../helm/kagent/kagent-ui-nodeport.yaml)
  is a second `NodePort` Service selecting the exact same pods, applied via
  `kubectl apply` right after the Helm install (see the Makefile's `kagent`
  target). `kind/cluster.yaml`'s `extraPortMappings` maps that to
  `http://localhost:8090`, same as every other UI here.

## Try it

```bash
make ai   # deploys Ollama + kagent + ObsAgent (not part of `make up`)
```

Open `http://localhost:8090`, pick **ObsAgent**, and ask it something that
needs live data rather than general knowledge:

- "What's the status of my cluster right now?"
- "Are any alerts currently firing?"
- "What Helm releases are deployed in the observability namespace?"
- "Query Mimir for the rate of `demo_orders_total` over the last 5 minutes."
- "Search Grafana for dashboards related to otel-demo."

Confirm everything's wired up before chatting, if you want to check first:

```bash
kubectl get agent obs-agent -n observability                 # READY / ACCEPTED = True
kubectl get remotemcpserver -n observability                 # both ACCEPTED = True
kubectl get modelconfig -n observability                     # default-model-config -> Ollama
```

## Why it matters

Most "AI + Kubernetes" demos either call out to a hosted API (cost, API key,
network dependency) or bolt a chatbot on top with no real access to cluster
or telemetry state (so it can only guess). ObsAgent is neither: genuine read
and write access to this stack's own Mimir/Loki/Tempo/Pyroscope data and the
cluster itself, running on a fully local model — so this demo stays true to
its own goal, a **self-contained**, laptop-sized environment with zero
external dependencies. And because it's wired into the same OTel pipeline as
everything else, ObsAgent's own behavior is exactly as observable as the
workloads it's helping you troubleshoot.

## Learn more

- [kagent on GitHub](https://github.com/kagent-dev/kagent)
- [kagent docs](https://kagent.dev/docs/kagent/introduction/installation)
- [Grafana Operator](https://github.com/grafana/grafana-operator) — provisions the
  service-account token `grafana-mcp` uses
- [Ollama guide](./ollama.md) — the local model kagent talks to
- [Alloy guide](./alloy.md) — the collector kagent's traces/logs flow through
