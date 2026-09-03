# posoco-ext-zai

> **Targets: native + js** — depends on `moonbitlang/async/http`.
> wasm-gc is not in the supported matrix.

Direct Z.ai / BigModel GLM access for
[Posoco](https://mooncakes.io/docs/colmugx/posoco): one provider for the real
platform APIs (`api.z.ai`, `open.bigmodel.cn`), pay-as-you-go balance, with
the GLM wire specifics owned end to end — thinking effort, tool calls,
streaming, and typed 429 quota verdicts. This is **not** a generic
OpenAI-compatible pass-through, and it does not serve the GLM Coding Plan
endpoints (`posoco-ext-zai-coding-plan` owns those).

## Ports contributed

Two structs, one layer each:

| Struct | Port | Responsibility |
|--------|------|----------------|
| `ZaiModelPort` | `ModelPort` | chat (streaming and buffered) plus client-side compact |
| `ZaiModelPort` | `Extension` | composes into `Agent(exts=[...])` as a model extension |
| `ZaiProvider` | `llm.ProviderFactory` / `llm.ApiKeyFactory` / `llm.RefreshableProviderFactory` | host-side provider registration: builds ports from generic settings/secret sources, runs the platform-choice login, and refreshes the catalog from the authenticated `/models` response |

## Usage

```bash
moon add colmugx/posoco-ext-zai
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-zai" @zai

let config = @zai.ZaiConfig::for_model(
  "sk-...",
  "glm-5.3", // default; catalog also serves glm-5.3-flash / 5.2 / 4.5-air
  base_url="https://api.z.ai",
  endpoint_prefix="/api/paas/v4",
)
let port = @zai.ZaiModelPort(config)
let catalog = port.model_catalog()
let router = @llm.RouterModelPort::from_catalogs(catalogs=[catalog])

// RouterModelPort is itself an Extension — compose it as the Agent's model.
let agent = @posoco.Agent(exts=[router, ..other_extensions], config~)
```

In Cetas hosts the provider is registered by name (`zai`); `/login zai`
collects credentials, `/model` lists the GLM catalog, and a model refresh
discovers the live list.

## Model discovery

The model list is fetched, not hardcoded. `refresh` issues exactly one
authenticated `GET {base}{prefix}/models` (OpenAI `list` envelope; both
platforms follow it) and builds one slot per discovered id, with the
configured model ordered first. Hosts persist the discovered list to
`~/.cetas/model_lists.json`; `build` then expands the same catalog offline
from those cached records, so a restart announces the full list without a
network request. With no cache the four-model preset stands until the first
refresh; malformed cache records degrade to the preset, never fail
composition.

Thinking profiles are a deterministic provider policy by GLM generation, so
a newly released id still gets the right picker without an extension update:
`glm-5*` exposes `low|high|max` (default `high`), `glm-4*` is an always-on
thinker with no selector, anything else gets no selector.

## Login: platform choice, then key

`/login zai` prompts twice:

1. **Select** — "Connect to bigmodel or Z.ai?" with the two platforms below.
2. **Secret** — the API key for the chosen platform.

The choice is recorded in the credential metadata (`platform`), so the stored
credential rebuilds its slots onto the matching endpoint after recomposition
and after `/login` — no extra settings key is required.

## Endpoints

| `platform` | base | billing |
| --- | --- | --- |
| `zai` (default) | `https://api.z.ai/api/paas/v4` | Z.ai international, balance |
| `bigmodel` | `https://open.bigmodel.cn/api/paas/v4` | BigModel China, balance |

Resolution order: credential `platform` metadata → `platform` setting →
`zai`. A `base_url` setting overrides the host but keeps the platform's path
prefix unless the URL carries its own path.

## GLM-specific behavior

- `thinking: {"type": "enabled"|"disabled"}` per model; `reasoning_effort`
  (`low|high|max`) only for GLM-5.x. GLM-4.x models are always-on thinkers
  with no effort selector.
- `reasoning_content` is resent on assistant messages that carry
  `tool_calls` (GLM 400s otherwise) and omitted otherwise, preserving the
  prefix cache.
- Streaming requests send `tool_stream: true` (incremental tool-call
  arguments) only for glm-4.6+ model ids; older models may reject the field.
- 429 classification follows z.ai's documented error-code table: quota
  verdicts (1308/1310/1316–1321) parse `{next_flush_time}` out of the message
  (UTC+8 when no explicit offset) into the typed `ModelError::RateLimited` —
  pair with posoco-ext-ratelimit for automatic resume. Transient verdicts
  (1302 concurrency, 1305 overload) classify as `RateLimited` with no reset
  time.
- `Accept-Language: en-US,en` request header, per z.ai docs.
- Usage decoding accounts for `prompt_tokens_details.cached_tokens`.

## Settings

| key | meaning |
| --- | --- |
| `api_key` | secret used when no credential is stored |
| `model` | default `glm-5.3` |
| `platform` | `zai` or `bigmodel`; ignored when the credential names one |
| `base_url` | endpoint override (keeps the platform prefix on bare hosts) |
| `reasoning_effort` | picker effort; `off` disables thinking |

## Dependencies

- `colmugx/posoco` — ModelPort trait + types
- `colmugx/posoco-devkit` — `ExtContext` logger helper
- `colmugx/posoco-ext-llm` — provider-neutral catalog/router
- `colmugx/posoco-ext-oauth` — credential store / auth prompt seams
- `colmugx/posoco-kit-chat-completions` — shared chat-completions protocol kit
- `colmugx/posoco-kit-compact-summary` — client-side compaction
- `moonbitlang/async/http` — HTTP transport
