# posoco-ext-openrouter

> **Targets: native + js** — depends on `moonbitlang/async/http`. The package
> still compiles on wasm/wasm-gc, where chat, compact, and refresh raise typed
> errors instead of doing HTTP.

A purpose-built OpenRouter
[`ModelPort`](https://mooncakes.io/docs/colmugx/posoco) for Posoco: one
endpoint (`/api/v1/chat/completions`), ApiKey auth only. The defining feature
is the `include_reasoning` switch — responses carry `reasoning_details`,
which the adapter stores verbatim on kernel `Reasoning.raw` (a
provider-defined replay payload the kernel keeps but never interprets) and
replays byte-exact on later assistant messages; encrypted chain-of-thought
continuation depends on it. This is **not** a general OpenAI-compatible
client: OpenRouter-specific behavior (own SSE processor, `error_type`
vocabulary, heartbeat/usage streaming semantics) is tuned for this endpoint.

## Ports contributed

| Struct | Port | Contribution |
|--------|------|--------------|
| `OpenRouterModelPort` | `ModelPort` | chat with optional streaming plus a summarize-based compact, over `/api/v1/chat/completions` |
| `OpenRouterModelPort` | `Extension` | self-reports one model in manifest `posoco_ext_openrouter` |
| `OpenRouterProvider` | `llm.ProviderFactory` / `llm.RefreshableProviderFactory` | settings → offline catalog snapshot; live `GET /models` catalog refresh |
| `OpenRouterApiKeyFactory` | `llm.ApiKeyFactory` | ApiKey login (the host's `/login openrouter method:api_key` path) |

## Usage

```bash
moon add colmugx/posoco-ext-openrouter
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-openrouter" @openrouter

let provider = @openrouter.OpenRouterProvider()
let factory : &@llm.ProviderFactory = provider
let source = @llm.ProviderConfigSource::ProviderConfigSource(
  settings=Some(
    Json::object(
      Map::from_array([
        ("model", Json::string("anthropic/claude-3.7-sonnet")),
        ("api_key", Json::string("sk-or-v1-...")),
        ("thinking_efforts", Json::array([Json::string("high")])),
        ("context_window", Json::number(200000.0)),
      ]),
    ),
  ),
)
let catalog = match factory.build(source) {
  @llm.ProviderBuildResult::Ready(catalog) => catalog
  @llm.ProviderBuildResult::Unconfigured =>
    abort("openrouter provider not configured")
}
let router = @llm.RouterModelPort::from_catalogs([catalog])

// RouterModelPort is itself an Extension — compose it as the Agent's model.
let agent = @posoco.Agent(exts=[router, ..other_extensions], config~)
```

`build` performs no network traffic: credential + settings (+ any cached
discovery records) resolve into a catalog snapshot. Hosts can also take the
factory path (what cetas does): register `OpenRouterProvider(ctx~) as
&llm.ProviderFactory`, `OpenRouterApiKeyFactory() as &llm.ApiKeyFactory`, and
the same provider as `&llm.RefreshableProviderFactory`, so settings
interpretation, `/login`, and catalog refresh all reuse one seam.

## Settings contract

The host passes the `providers.openrouter` object from `.cetas/settings.json`
into `ProviderConfigSource.settings` verbatim; this extension interprets it:

```json
{
  "providers": {
    "openrouter": {
      "model": "anthropic/claude-3.7-sonnet",
      "api_key": "sk-or-v1-...",
      "thinking_efforts": ["low", "high"],
      "context_window": 200000,
      "compact_threshold": 0.85,
      "http_referer": "https://myapp.example",
      "title": "My App"
    }
  }
}
```

| Field | Required | Meaning |
|-------|----------|---------|
| `model` | yes* | vendor/slug model id (`anthropic/claude-3.7-sonnet`); no format validation — the server owns naming. Empty or non-string values are typed composition failures; a **missing** `model` means `Unconfigured` (the login-first flow parks the provider until settings supply one) |
| `api_key` | no | normally injected by `/login` (persisted in the host credential store). The `effective_credential("openrouter")` ApiKey wins over this field; an OAuth credential is a typed composition failure — this extension is ApiKey-only |
| `base_url` | no | default `https://openrouter.ai/api/v1`; kept overridable for tests and proxies |
| `thinking_efforts` | no | string array of selectable reasoning levels, passed through verbatim as the wire `reasoning_effort`; entries must be non-empty, unique, and never the reserved words `off`/`on` (violations are typed composition failures). Absent = plain off/on toggle, initial off |
| `context_window` | no | positive integer, token capacity. Absent = unknown, auto-compact stays off for this model rather than guessing a window |
| `compact_threshold` | no | fraction in (0, 1], the auto-compact trigger point; declaring it requires `context_window`. Absent = the host/core default (0.88) applies |
| `http_referer` / `title` | no | `HTTP-Referer` / `X-Title` attribution headers; rankings only, never inference behavior |

\* Required for the static settings build only — cached discovery records or
a live refresh replace it (see below).

### Reasoning effort semantics

- **No declared levels**: the choice surface is `off` / `on`, initial `off`.
  No conventional `low/medium/high` set is ever fabricated.
- **Declared levels**: the surface is `off` plus each declared value; the
  first value is the default.
- Wire mapping: `off` omits both fields entirely; `on` without a level sends
  `"include_reasoning": true`; `on` plus a level additionally sends the
  top-level `"reasoning_effort": "<level>"` verbatim.

## Behavior notes

- **reasoning_details replay** — the whole response `reasoning_details` array
  is stored verbatim on `Reasoning.raw`; element shapes (`reasoning.summary`,
  `reasoning.encrypted`, `reasoning.text`, `reasoning.server_tool_call`) are
  never interpreted. Assistant messages replay the array untouched —
  encrypted blocks must survive byte-exact and in order — falling back to the
  plain `reasoning` string when no raw payload exists. DeepSeek-style
  `reasoning_content` is never used.
- **Own SSE processor** — the shared chat-completions kit parser only
  recognizes `delta.reasoning_content`; OpenRouter streams `delta.reasoning`
  (string increments) plus `delta.reasoning_details` (structured fragments
  arriving piecewise), so this endpoint carries its own processor with the
  same tool-call stitching and usage semantics as the kit.
- **Streaming wire facts** — heartbeat comment lines (`: OPENROUTER
  PROCESSING`) are skipped; requests send `"stream": true` only
  (`stream_options.include_usage` is deprecated — usage rides the final chunk
  automatically); the driver keeps draining past `finish_reason` until
  `[DONE]` so the trailing usage chunk lands, and a late `[DONE]` never
  clobbers the recorded finish reason. EOF without a terminal marker stays a
  loud failure unless a complete tool call was assembled.
- **Error classification** — `error.metadata.error_type` is preferred over
  bare status codes, and only short enum-like labels cross into failure
  messages (free text is dropped): `payment_required` drives payment
  semantics on any status; 429 becomes a typed `RateLimited` with the reset
  time taken from the body, `Retry-After`, or `X-RateLimit-Reset`. A
  structured `error` object under HTTP 200 is a provider failure (Transport),
  never a parse failure.
- **prompt_cache_key (opt-in)** — `send_prompt_cache_key` (default off) sends
  a stable session-derived key (`"posoco-" + session_id`). OpenRouter fronts
  many upstream providers, not all of which accept the parameter, so once one
  explicitly rejects it the key is suppressed for the rest of the process.
- **Image input** — discovery's `architecture.input_modalities` decides:
  image-capable models advertise `image_in` and encode image blocks as typed
  content parts; everything else downgrades them to explicit placeholders.

## Model discovery and refresh

`OpenRouterProvider` also implements `llm.RefreshableProviderFactory`:
`refresh` performs one authenticated `GET {base_url}/models` and expands the
response into a multi-slot catalog — the configured model pinned first, the
endpoint's own order preserved for the rest. Discovery metadata
(`reasoning.supported_efforts` / `default_effort`, `context_length`,
`architecture.input_modalities`) replaces hand-declared settings: once
discovery has run, the models' own numbers own the effort surface and context
windows. An empty response raises a typed composition error; transport,
schema, or HTTP failures never fall back to the static single-model catalog.
`build` also expands host-cached discovery records offline, so a restart
after login+refresh announces the full catalog even with no settings at all.

## Boundary

- **This extension**: OpenRouter endpoint semantics — request encoding,
  response decoding, the own SSE processor, error classification, ApiKey
  login.
- **`posoco-ext-llm`**: catalog aggregation and the `/model` command,
  permanently provider-neutral.
- **`cetas-core`**: routes the `openrouter` settings id to this extension's
  factories.
- Every other OpenAI-compatible endpoint belongs to
  `posoco-ext-openai-compatible`: unclaimed settings ids fall through to it;
  this extension claims only `openrouter`.

## Debugging: wire log (js/bun)

Set the `POSOCO_WIRE_LOG` environment variable to a file path and streaming
requests append every raw SSE data payload to it, one per line (js/bun only;
native is a no-op). The file holds full provider traffic — keep it for local
debugging only.

```bash
POSOCO_WIRE_LOG=~/.cetas/wire.log bun run start
```

## Dependencies

- `colmugx/posoco` — `ModelPort` trait + kernel types (`Reasoning.raw` carries `reasoning_details`)
- `colmugx/posoco-devkit` — `ExtContext` logger helper
- `colmugx/posoco-kit-chat-completions` — error classification, usage/cache-key helpers (the SSE processor is deliberately not shared)
- `colmugx/posoco-kit-compact-summary` — summarize-based compaction
- `colmugx/posoco-ext-llm` — provider-neutral catalog/router
- `colmugx/posoco-ext-oauth` — `ApiKeyCredential` / `AuthPromptInteraction`
- `moonbitlang/async/http` — HTTP transport
