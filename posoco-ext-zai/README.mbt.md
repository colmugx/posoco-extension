# posoco-ext-zai

> **Targets: native + js** — depends on `moonbitlang/async/http`.
> wasm-gc is not in the supported matrix.

Direct Z.ai / BigModel GLM access for
[Posoco](https://mooncakes.io/docs/colmugx/posoco): one provider for the real
platform APIs (`api.z.ai`, `open.bigmodel.cn`), pay-as-you-go balance, on the
platforms' **Anthropic-compatible Messages route** (`/api/anthropic`) through
`posoco-kit-messages`. Wire specifics owned end to end — the uniform
thinking/effort posture, signed-thinking replay, native tool_result
attachments, streaming, and typed 429 quota verdicts. This is **not** a
generic OpenAI-compatible pass-through, and it does not serve the GLM Coding
Plan endpoints (the coding-plan adaptor owns those).

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
  "glm-5.3", // default; the preset catalog also serves glm-5.3-flash
  base_url="https://api.z.ai",
  endpoint_prefix="/api/anthropic",
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
authenticated `GET {base}/api/paas/v4/models` — model-catalog discovery stays
on the platform's OpenAI-compatible list route (a management surface whose
envelope `parse_zai_models` already speaks), while chat traffic runs on the
Messages route. Discovered ids build one slot each, with the configured model
ordered first. Hosts persist the discovered list to
`~/.cetas/model_lists.json`; `build` then expands the same catalog offline
from those cached records, so a restart announces the full list without a
network request. With no cache the two-model preset stands (`glm-5.3`,
`glm-5.3-flash`) until the first refresh; malformed cache records degrade to
the preset, never fail composition.

There are **no per-model thinking policies**: every model id — preset,
discovered, or hand-configured — shares one uniform posture (below). Legacy
generations (GLM-4.x, GLM-5.2) are outside the supported set; ids that still
resolve get the same uniform posture without a correctness guarantee.

## Login: platform choice, then key

`/login zai` prompts twice:

1. **Select** — "Connect to bigmodel or Z.ai?" with the two platforms below.
2. **Secret** — the API key for the chosen platform.

The choice is recorded in the credential metadata (`platform`), so the stored
credential rebuilds its slots onto the matching endpoint after recomposition
and after `/login` — no extra settings key is required.

## Endpoints

| `platform` | base | chat route | billing |
| --- | --- | --- | --- |
| `zai` (default) | `https://api.z.ai` | `/api/anthropic/v1/messages` | Z.ai international, balance |
| `bigmodel` | `https://open.bigmodel.cn` | `/api/anthropic/v1/messages` | BigModel China, balance |

Resolution order: credential `platform` metadata → `platform` setting →
`zai`. A `base_url` setting overrides the host but keeps the platform's path
prefix unless the URL carries its own path.

## Messages-protocol behavior

- **Uniform thinking posture, no exceptions**: every request sends
  `thinking: {"type": "enabled"}` (no `budget_tokens` — the budget-free
  enabled dialect the GLM Messages endpoint accepts) plus the platform's
  top-level `reasoning_effort` (`low|high|max`, default `high`). Thinking
  cannot be disabled: forced-thinking models answer
  `thinking: {"type": "disabled"}` with HTTP 400, so `off` is not offered and
  `with_reasoning_effort("off")` is a typed composition error.
- Signed thinking blocks replay verbatim: the kit stores the entire assistant
  wire block sequence in the reasoning replay envelope and re-emits it on the
  next turn after fingerprint verification — no `reasoning_content` resend
  hacks, correct interleaving of thinking with tool calls.
- Tool results are native `tool_result` blocks; attachments ride as sibling
  image blocks on vision models. Non-vision models degrade user images and
  tool attachments to explicit `[Attached …, omitted]` placeholders — never a
  silent drop.
- `max_tokens` is always sent (Messages requires it): the host chat option
  wins, otherwise the config default 32768 (settings key `max_output_tokens`).
- `temperature` passes through; values above 1.0 are a typed request error
  (the Messages contract is [0, 1]).
- Headers: `Authorization: Bearer`, `anthropic-version: 2023-06-01`,
  `Accept-Language: en-US,en`. No `anthropic-beta` features are negotiated.
- 429 classification follows z.ai's documented error-code table (devkit's
  protocol-neutral quota-verdict decoder): quota verdicts
  (1308/1310/1316–1321) parse the flush time out of the message (UTC+8 when
  no explicit offset) into the typed `ModelError::RateLimited` — pair with a
  rate-limit extension for automatic resume. Transient verdicts (1302
  concurrency, 1305 overload) classify as `RateLimited` with no reset time.

## Context window

Z.ai serves no machine-readable context capacity, so the window stays
unknown unless the host declares one: a `context_window` settings key (whole
token count) states the configured model's capacity. It feeds the provider
config that the `ctx` status segment and auto-compact read; unknown windows
are never guessed, and catalog ids other than the configured model keep an
unknown window.

## Settings

| key | meaning |
| --- | --- |
| `api_key` | secret used when no credential is stored |
| `model` | default `glm-5.3` |
| `platform` | `zai` or `bigmodel`; ignored when the credential names one |
| `base_url` | endpoint override (keeps the platform prefix on bare hosts) |
| `reasoning_effort` | picker effort `low\|high\|max`; there is no `off` |
| `context_window` | declared model capacity in tokens; enables the `ctx` window/percent figures and auto-compact |
| `max_output_tokens` | output cap backing the required `max_tokens` field; default 32768 |

## Dependencies

- `colmugx/posoco` — ModelPort trait + types
- `posoco/devkit` — `ExtContext` helper + protocol-neutral 429 verdict decoder
- `posoco/ext-llm` — provider-neutral catalog/router
- `posoco/ext-oauth` — credential store / auth prompt seams
- `colmugx/posoco-kit-messages` — Messages wire codec, replay envelope, SSE
- `colmugx/posoco-kit-compact-summary` — client-side compaction
- `moonbitlang/async/http` — HTTP transport
