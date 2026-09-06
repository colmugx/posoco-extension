# posoco-ext-opencode-zen

> **Targets: native + js** — depends on `moonbitlang/async/http`. wasm-gc is
> not in the supported matrix, but chat, compact, and refresh supply
> type-complete raising fallbacks so downstream `mbti` resolution never
> breaks.

A named [`ProviderFactory`](https://mooncakes.io/docs/colmugx/posoco) for the
[OpenCode Zen](https://opencode.ai/docs/zen/) gateway. Zen exposes a curated
catalog of coding models — Claude / GPT / Gemini / Qwen / DeepSeek / GLM /
Kimi, with ids like `claude-opus-5`, `gpt-5.1-codex`, `glm-5.2` — behind
one API key. This extension publishes them as the `opencode` provider, so
`/login opencode` and `/model` work out of the box.

## Ports contributed

| Struct | Port | Responsibility |
|--------|------|----------------|
| `OpenCodeZenModelPort` | `ModelPort` | chat and streaming chat over Zen's GLM-flavored Chat Completions wire; reports `context_window` / `compact_threshold` to the Agent's auto-compact policy |
| `OpenCodeZenProvider` | `llm.ProviderFactory` | static `build`: a no-network catalog over the resolved credential/endpoint/model (expanded offline from host-cached records when available) |
| `OpenCodeZenProvider` | `llm.RefreshableProviderFactory` | live `refresh`: one authenticated `/models` call, one slot per discovered model |
| `OpenCodeZenProvider` | `llm.ApiKeyFactory` | the `/login opencode` secret prompt |

The extension implements **no** `Extension::manifest`: it is a
factory-registered provider, composed indirectly through cetas-core's factory
registry (same shape as deepseek/kimi and the other named providers), never
held as a top-level extension by the Agent. Slots wrap the port in a retry
decorator (see [Retry](#retry)).

## Usage

```bash
moon add colmugx/posoco-ext-opencode-zen
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-opencode-zen" @opencode_zen
//            (+ "colmugx/posoco-ext-llm" @llm for the router)

let provider = @opencode_zen.OpenCodeZenProvider()
let config = @opencode_zen.OpenCodeZenConfig(
  "sk-zen-...",
  base_url="https://opencode.ai/zen/v1",
  model="claude-sonnet-5",
)
let catalog = @opencode_zen.zen_static_catalog(config, provider)
let router = @llm.RouterModelPort::from_catalogs(catalogs=[catalog])

// RouterModelPort is itself an Extension — compose it as the Agent's model.
let agent = @posoco.Agent(exts=[router, ..other_extensions], config~)
```

The constructor requires `base_url` and `model` (the settings defaults below
apply on the factory path). Hosts can also take the factory path (what cetas
does): register `OpenCodeZenProvider(ctx~)` in the `ProviderFactory`,
`ApiKeyFactory`, and `RefreshableProviderFactory` lists, and settings,
`/login opencode`, and catalog refresh all reuse the same seam.

## The wire: self-contained GLM flavor

Zen's chat endpoint (`https://opencode.ai/zen/v1/chat/completions`) speaks a
GLM-flavored Chat Completions variant. This extension owns the whole wire —
encode, decode, SSE loop, HTTP error classification, wire log — and keeps the
non-standard spellings downstream needs:

- **`thinking` object**: when thinking is on, the request sends
  `thinking: {"type": "enabled"}` — never a bare boolean, which strict
  upstreams reject. Thinking off omits `thinking` and `reasoning_effort`
  entirely, so the endpoint applies its own default.
- **`reasoning_effort`**: a selected level is sent verbatim as the top-level
  field.
- **`reasoning_content` echo**: assistant messages resend reasoning whenever
  it is present (keep-all) — DeepSeek-style upstreams require it on tool-call
  turns and tolerate it elsewhere.
- **`stream_options.include_usage`**: always set on streaming requests, or
  usage never arrives.

Only the SSE line parsing, 429 classification, and content-encoding helpers
are shared with the other chat-completions providers (via
`posoco-kit-chat-completions`); every spelling where Zen's upstream differs
from standard OpenAI lives in this package.

## Reasoning presets

Zen's `/models` publishes no capability fields, so the per-model reasoning
surface is a curated preset table (`src/efforts.mbt`) keyed by bare model id.
Its source is the `opencode` provider's `reasoning_options` in
[models.dev](https://models.dev/api.json) — the same catalog OpenCode itself
reads.

- Level-bearing models expose exactly their declared levels plus `off` when
  thinking can be disabled; the default level is `high` when offered, else
  the first declared level.
- Toggle-only models expose `off` / `on`.
- Models absent from the table are plain chat: no selector, and the request
  omits the reasoning surface entirely.

A stale entry degrades to a legible upstream 400 naming the rejected level —
levels pass through verbatim, and the server owns the valid names.

## Settings contract

`.cetas/settings.json` — all keys optional, Zen has conventional defaults:

```json
{
  "providers": {
    "opencode": {
      "api_key": "sk-zen-...",
      "model": "claude-sonnet-5"
    }
  }
}
```

| Field | Required | Default | Meaning |
|---|---|---|---|
| `api_key` | no | — | Also injectable via `/login opencode`; persisted to `~/.cetas/credentials/opencode.json`. A credential wins over the setting; with neither, the provider is Unconfigured (no slot, no error) |
| `model` | no | `claude-sonnet-5` | Initial model for the static build; after a refresh the full catalog is selectable in `/model` |
| `base_url` | no | `https://opencode.ai/zen/v1` | Override only for private/mirror deployments. `endpoint_prefix` stays empty — the base URL already carries `/v1` |

> The provider id is fixed to `"opencode"` (`zen_provider_id`, centralized in
> `src/catalog.mbt`). Once registered in cetas-core's `provider_factories()`,
> that id is claimed: a `providers.opencode` settings entry never falls
> through to the generic openai-compatible adapter.

Malformed values (empty or non-string settings) are typed composition
failures, so a broken `providers.opencode` entry cannot produce a
half-configured agent.

## `/login`

```bash
/login opencode                # via ApiKeyFactory, prompts "OpenCode Zen API key"
/login opencode method:api_key # equivalent explicit form
```

The secret must be non-empty; an empty key is rejected with
`OAuthError::ParseError`. OAuth credentials are not supported for this
provider and fail composition with a typed error.

## `/model` catalog

- **Static build** (agent startup): one slot over `settings.model` (default
  `claude-sonnet-5`) — deliberately no network, so startup never fails on
  Zen `/models` flakiness. If the host cached records from a previous
  refresh, `build` expands them offline into the full multi-slot catalog, so
  restarts announce the complete list immediately; malformed caches degrade
  to the single static slot.
- **Refresh** (`/model refresh` or capability discovery): one authenticated
  `GET /models` (30s timeout). The `/models` listing is publicly readable
  today, but the request still carries `Authorization: Bearer` so it keeps
  working if Zen later gates discovery. The configured model is pinned first;
  the rest keep server order. Transport, schema, or HTTP failures — including
  an empty list — are typed composition failures; this path never falls back
  to the static catalog.
- Slot ids are `opencode/<bare-model-id>` (e.g. `opencode/claude-opus-5`) —
  Zen's ids are bare, without the `opencode/` prefix — and
  `display_group="zen"` tabs them together in the picker.

Every request carries OpenCode routing headers: `x-opencode-project` and
`x-opencode-client` set to `posoco`, a process-stable `x-opencode-session`,
and a fresh `x-opencode-request` per request (`User-Agent:
posoco/opencode-zen`). This mirrors the sticky-session behavior of the
OpenCode client while honestly identifying posoco.

## Compact

No compact endpoint exists, so Zen compacts locally with an OpenCode-style
anchored summary: a keep-recent budget of `clamp(2000..15000, 25% of usable)`
where usable is the model window minus a 20k compaction reserve (15k
ceiling when no window is known — a window is never guessed), the previous
anchored summary folded into the update prompt, and one non-streaming
summary call with an empty toolset. The summary plus the kept recent
messages replace the transcript.

## Retry

Slots wrap the model port in a retry decorator for Zen's transient failure
classes: marker-less EOF truncation, mid-stream connection resets
(`stage=read_stream`), and gateway 503s. At most 3 retries after the first
failure, with a 2s initial delay doubling per retry — the parameters
OpenCode's session retry uses. An EOF that leaves every tool call structurally
complete is not an error at all: the stream validator passes it through
directly, so it never enters retry. Other errors (pre-stream transport
failures, other HTTP statuses) are never retried.

## Boundaries

- **This extension**: Zen endpoint conventions, the GLM-flavored chat wire
  (encode/decode/SSE/error classification), `/models` decoding, the multi-slot
  catalog, and the `/login` prompt.
- **`posoco-ext-llm`**: catalog aggregation and the `/model` command,
  provider-neutral forever.
- **`cetas-core`**: registers `OpenCodeZenProvider` into
  `provider_factories()` — one place — and `/login`, `/model`, and catalog
  refresh follow automatically.
- **`cetas-js`**: host-owned process caches and file IO; it is unaware Zen
  exists.

## Dependencies

- `colmugx/posoco` — `ModelPort` trait + `ModelError` / `CompositionError` types
- `colmugx/posoco-devkit` — `ExtContext`
- `colmugx/posoco-ext-llm` — `ProviderFactory` / `RefreshableProviderFactory` / `ApiKeyFactory` / `ProviderModelCatalog` / `ModelSlot`
- `colmugx/posoco-ext-oauth` — `ApiKeyCredential` / `AuthPromptInteraction`
- `colmugx/posoco-kit-chat-completions` — shared SSE line parsing / 429 classification / content-encoding helpers
- `colmugx/posoco-kit-compact-summary` — anchored summary template, cut selection, and Replace builder
- `moonbitlang/async/http` — `/models` and chat transport
