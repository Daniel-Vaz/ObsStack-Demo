# Ollama

**In one line:** a local server that runs open LLMs (like `llama3.1:8b`) so
this demo needs no external AI API key.

> Chart: `ollama-helm/ollama` (1.65.0) ·
> config: [`helm/ollama/values.yaml`](../../helm/ollama/values.yaml) ·
> access: cluster-internal only — no web UI

> [!NOTE]
> **Optional, not part of `make up`.** Deploy it with `make ai` (which also
> deploys [kagent](./kagent.md)) — resource-heavy enough that it's opt-in
> rather than always-on.

## What it is

[**Ollama**](https://ollama.com/) packages open-weight LLMs (Llama, Mistral,
and others) behind a simple local REST API. Instead of calling out to a
hosted model provider (OpenAI, Anthropic, ...), anything in the cluster can
send a request to Ollama's `/api/generate` (or OpenAI-compatible `/v1/chat`)
endpoint and get a response from a model running right there in the pod.

## Where it fits among the others

Ollama isn't part of the four-signal observability pipeline (metrics, logs,
traces, profiles) — it's the **model backend for [kagent](./kagent.md)**, the
AI agent framework deployed alongside it. Everywhere else in this demo,
"backend" means a telemetry store (Mimir, Loki, Tempo, Pyroscope); here it
means an inference server:

```
  kagent's ObsAgent  ──chat/completion requests──▶  Ollama  ──▶  llama3.1:8b
  (AI agent)              (OpenAI-shaped API)         (local, CPU inference)
```

## How we use it in this demo

Ollama is deployed by `make ollama` (part of the `ai` target group — `make
ai`, **not** `make up`) into the `observability` namespace — the same
namespace as everything else in this demo, kept single-namespace for
simplicity.

- **`llama3.1:8b`, pulled at pod startup.** [`helm/ollama/values.yaml`](../../helm/ollama/values.yaml)
  lists `llama3.1:8b` under both `ollama.models.pull` and `ollama.models.run`: pulled
  (~4.9GB download) and then loaded into memory so the first request from
  kagent isn't slowed by a cold load. This happens via a `postStart` lifecycle
  hook — Kubernetes doesn't mark the container `Running` until it completes,
  so the `ollama` Makefile target uses a generous `OLLAMA_TIMEOUT` (default
  `20m`) rather than the stack's usual `HELM_TIMEOUT`.
- **CPU only, no persistence.** There's no GPU in this kind/Podman setup, so
  inference is CPU-bound — fine for the occasional chat query an agent
  makes, not for load. No PersistentVolumeClaim either: model files live in
  the container filesystem and get re-pulled on every pod start. A PVC
  wouldn't survive `make down` anyway (kind's default storage backs onto the
  node container's own filesystem), so this demo accepts the re-pull cost
  instead.
- **Cluster-internal only.** Unlike Grafana/Alloy/Headlamp/etc., Ollama gets
  no NodePort or `localhost` URL — nothing outside the cluster needs to talk
  to it directly. kagent reaches it at
  `ollama.observability.svc.cluster.local:11434`.

## Try it

There's no UI of its own — the way to "see" it is via
[kagent's ObsAgent](./kagent.md), which chats through it. To talk to Ollama
directly instead:

```bash
make ai   # deploys Ollama + kagent + ObsAgent (not part of `make up`)
kubectl port-forward -n observability svc/ollama 11434:11434
curl http://localhost:11434/api/generate -d '{
  "model": "llama3.1:8b",
  "prompt": "In one sentence, what is Kubernetes?",
  "stream": false
}'
```

## Why it matters

Wiring an AI agent framework to a paid, hosted model means every run needs
an API key and incurs a cost. A local model removes that friction entirely:
`make ai` alone gets you a working model backend, no signup, no key, no
bill — so ObsAgent stays true to this demo's own goal, a self-contained
environment with zero external dependencies. The tradeoff is capability and
speed (a CPU-run `llama3.1:8b` is slower and less capable than a frontier
hosted model) — a fair trade for a demo.

## Learn more

- [Ollama](https://ollama.com/)
- [ollama-helm chart](https://github.com/otwld/ollama-helm)
- [kagent guide](./kagent.md) — the agent framework that talks to this
