# Ollama

**In one line:** a local server that runs open LLMs (like `llama3.2:3b`) so
this demo needs no external AI API key.

> Chart: `ollama-helm/ollama` (1.65.0) ·
> config: [`helm/ollama/values.yaml`](../../helm/ollama/values.yaml) ·
> access: cluster-internal only — no web UI

> [!NOTE]
> **Part of `make up`, but the heaviest component.** Ollama backs Grafana's
> Graft AI assistant, so it's deployed by default — expect the first `make up`
> to take a while (multiple CPUs, several GiB of RAM, ~2GB model pull).

## What it is

[**Ollama**](https://ollama.com/) packages open-weight LLMs (Llama, Mistral,
and others) behind a simple local REST API. Instead of calling out to a
hosted model provider (OpenAI, Anthropic, ...), anything in the cluster can
send a request to Ollama's `/api/generate` (or OpenAI-compatible `/v1/chat`)
endpoint and get a response from a model running right there in the pod.

## Where it fits among the others

Ollama isn't part of the four-signal observability pipeline (metrics, logs,
traces, profiles) — it's the **model backend for Grafana's Graft AI
assistant**. Grafana's `grafana-llm-app` plugin points at Ollama's
OpenAI-compatible API (see [`helm/grafana/values.yaml`](../../helm/grafana/values.yaml)),
and the Graft app plugin chats through that. Everywhere else in this demo,
"backend" means a telemetry store (Mimir, Loki, Tempo, Pyroscope); here it
means an inference server:

```
  Grafana Graft app  ──▶  grafana-llm-app  ──chat/completion──▶  Ollama  ──▶  llama3.2:3b
  (chat UI in Grafana)     (LLM plugin)      (OpenAI /v1 API)     (local, CPU inference)
```

## How we use it in this demo

Ollama is deployed by `make ollama` (folded into `make up`) into the
`observability` namespace — the same namespace as everything else in this
demo, kept single-namespace for simplicity.

- **`llama3.2:3b`, pulled at pod startup.** [`helm/ollama/values.yaml`](../../helm/ollama/values.yaml)
  lists `llama3.2:3b` under both `ollama.models.pull` and `ollama.models.run`: pulled
  (~2GB download) and then loaded into memory so the first request from
  Graft isn't slowed by a cold load. This happens via a `postStart` lifecycle
  hook — Kubernetes doesn't mark the container `Running` until it completes,
  so the `ollama` Makefile target uses a generous `OLLAMA_TIMEOUT` (default
  `20m`) rather than the stack's usual `HELM_TIMEOUT`. `OLLAMA_KEEP_ALIVE=24h`
  (set via `extraEnv`) keeps the model resident so it doesn't unload after the
  default 5-minute idle and pay a cold reload on the next query.
- **Why 3b, not a bigger model.** Grafana's `grafana-llm-app` plugin hardcodes
  a 2-minute HTTP timeout on its call to Ollama. On this CPU-only box an 8B
  model generates at ~2-3 tok/s, so a normal Graft turn (large tool-schema
  prompt + a few hundred output tokens) runs past 2 minutes and the request
  fails. `llama3.2:3b` runs ~2.4x faster (~6 tok/s, a ~300-token answer in ~45s
  vs ~115s), staying inside that timeout while remaining capable enough for
  Graft's tool-calling.
- **CPU only, no persistence.** WSL2 exposes no GPU render node (`/dev/dri`) or
  NPU (`/dev/accel`) into Linux — only `/dev/dxg` — and Ollama supports only
  NVIDIA/AMD GPUs regardless, so inference is CPU-bound (the pod is given a
  generous CPU slice in `resources`). No PersistentVolumeClaim either: model
  files live in the container filesystem and get re-pulled on every pod start.
  A PVC wouldn't survive `make down` anyway (kind's default storage backs onto
  the node container's own filesystem), so this demo accepts the re-pull cost
  instead.
- **Cluster-internal only.** Unlike Grafana/Alloy/Headlamp/etc., Ollama gets
  no NodePort or `localhost` URL — nothing outside the cluster needs to talk
  to it directly. Grafana reaches it at
  `ollama.observability.svc.cluster.local:11434`.

## Try it

There's no UI of its own — the way to "see" it is through Grafana's **Graft**
assistant (find it in the Grafana nav), which chats through it. To talk to
Ollama directly instead:

```bash
kubectl port-forward -n observability svc/ollama 11434:11434
curl http://localhost:11434/api/generate -d '{
  "model": "llama3.2:3b",
  "prompt": "In one sentence, what is Kubernetes?",
  "stream": false
}'
```

## Why it matters

Wiring an AI assistant to a paid, hosted model means every run needs an API
key and incurs a cost. A local model removes that friction entirely: `make up`
alone gets you a working model backend, no signup, no key, no bill — so Graft
stays true to this demo's own goal, a self-contained environment with zero
external dependencies. The tradeoff is capability and speed (a CPU-run
`llama3.2:3b` is slower and less capable than a frontier hosted model) — a
fair trade for a demo.

## Learn more

- [Ollama](https://ollama.com/)
- [ollama-helm chart](https://github.com/otwld/ollama-helm)
- [Grafana LLM plugin](https://grafana.com/docs/grafana-cloud/machine-learning/llm/) — how Grafana connects to this
- [Graft](https://github.com/vikshana/vikshana-graft-app) — the Grafana AI assistant that chats through it
