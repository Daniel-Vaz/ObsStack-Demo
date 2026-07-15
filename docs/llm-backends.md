# AI assistant LLM backend: the Ollama testing mode

> **This is an advanced, opt-in option for specific testing scenarios.**
> The default setup points Grafana's AI assistant at Azure AI Foundry, and
> every other document in this repo describes that default. Reach for the
> mode below only when you specifically want a local, key-less model backend.

## The default (no flag needed)

`make up` wires Grafana's `grafana-llm-app` plugin (and the Graft assistant
built on it) up to an **Azure AI Foundry** endpoint:

- Provider is `custom` (OpenAI wire format) pointed at
  `https://dvaz-tests-resource.services.ai.azure.com/openai` - see
  [`helm/grafana/values.yaml`](../helm/grafana/values.yaml)'s `llm` block.
- The API key comes from `AZURE_LLM_API_KEY` in `.env` (gitignored), which the
  Makefile's `grafana` target passes to Helm as `--set-string llm.apiKey=...`.
  It's delivered to the plugin via `secureJsonData` in the file-based plugin
  provisioning ConfigMap - see
  [`templates/grafana.yaml`](../helm/grafana/templates/grafana.yaml).
- Both of the plugin's `base`/`large` model slots map to the `gpt-5.4-mini`
  deployment.

See [architecture.md](architecture.md) for the full design.

## The `LLM_BACKEND=ollama` testing mode

Set `LLM_BACKEND=ollama` to run the AI assistant against
[Ollama](solutions/ollama.md), deployed in-cluster, instead of Azure AI
Foundry. This is useful when you want a fully local, key-less model backend -
for example while testing offline, or without an Azure API key to hand.

```bash
make up LLM_BACKEND=ollama     # bring the whole stack up in this mode
```

`LLM_BACKEND` also applies to `make grafana`.

Everything else about the demo is identical to the default. Only **which
model backend Grafana's AI assistant talks to** changes.

### What changes

| | Default (Azure AI Foundry) | `LLM_BACKEND=ollama` |
|---|---|---|
| Model provider | Azure AI Foundry (`gpt-5.4-mini`) | in-cluster Ollama (`llama3.2:3b`) |
| `make up` deploys | - | Ollama (`ollama-helm/ollama`), plus a `postStart` model pull |
| API key | `AZURE_LLM_API_KEY` from `.env` | none - Ollama ignores auth |
| Response speed | as fast as the Azure deployment | slow - CPU-only inference |

Under the hood, [`helm/grafana/values.yaml`](../helm/grafana/values.yaml) sets
the Azure defaults, and a sibling
[`values-ollama-llm.yaml`](../helm/grafana/values-ollama-llm.yaml) overlay is
applied (via an extra `--values`) only when `LLM_BACKEND=ollama`, swapping the
`llm.url`/`llm.model`/`llm.apiKey` values over to Ollama's in-cluster address.

### Switching between modes

You can switch modes with `make up LLM_BACKEND=...` without recreating the
cluster - `make grafana` re-provisions the plugin config either way. In
`LLM_BACKEND=ollama`, also run `make ollama` (or a fresh `make up`) to deploy
the model backend itself.
