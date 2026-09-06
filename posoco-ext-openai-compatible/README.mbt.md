# posoco-ext-openai-compatible

> **Targets: native + js** — depends on `moonbitlang/async/http`. The package
> still compiles on wasm/wasm-gc: chat and compact supply typed raising
> fallbacks so downstream `mbti` resolution never breaks.

A generic OpenAI Chat Completions (`POST {base_url}{prefix}/chat/completions`)
[`ModelPort`](https://mooncakes.io/docs/colmugx/posoco) implementation for
Posoco. It speaks only the standard protocol and is **not** bound to any
vendor: one instance is scoped to exactly one provider id, and the host
(cetas-core) constructs one instance per custom provider id in
`.cetas/settings.json`.

Where it sits against the OpenAI Responses adapter:

| Extension | Protocol | Purpose |
|---|---|---|
| `posoco-ext-openai` | `/responses` (OpenAI Responses API) | OpenAI official + Codex OAuth |
| this extension | `/chat/completions` (standard) | any standard endpoint, e.g. Qwen's DashScope compatible-mode server |

## Ports contributed

Two structs, one layer each:

| Struct | Port | Responsibility |
|--------|------|----------------|
| `OpenAICompatibleModelPort` | `ModelPort` | chat and streaming chat plus a summarize-based compact over the standard wire; reports `context_window` / `compact_threshold` to the Agent's auto-compact policy |
| `OpenAICompatibleProvider` | `llm.ProviderFactory` / `llm.ApiKeyFactory` | host-side registration: builds the catalog for its one provider id from a generic settings/secret source and owns the API-key login prompt |

The extension implements **no** `Extension::manifest` and never composes as a
top-level extension: it participates through cetas-core's factory registry,
the same shape as the deepseek/kimi/openai provider extensions. The adapter
also never reads the settings map itself and never decides which ids it
serves — the host hands it an opaque `ProviderConfigSource` for one id.

## Usage

```bash
moon add colmugx/posoco-ext-openai-compatible
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-openai-compatible" @openai_compatible
//            (+ "colmugx/posoco-ext-llm" @llm for the router)

let config = @openai_compatible.OpenAICompatibleConfig(
  "sk-...",
  base_url="https://dashscope.aliyuncs.com/compatible-mode/v1",
  model="qwen-plus",
)
let port = @openai_compatible.OpenAICompatibleModelPort("qwen", config)
let catalog = port.model_catalog()
let router = @llm.RouterModelPort::from_catalogs(catalogs=[catalog])

// RouterModelPort is itself an Extension — compose it as the Agent's model.
let agent = @posoco.Agent(exts=[router, ..other_extensions], config~)
```

Hosts can also take the factory path (what cetas does): cetas-core's
`compatible_provider_factories(settings, ctx)` mints one
`OpenAICompatibleProvider` per settings id not claimed by a static provider,
so custom ids participate identically to static ones in catalog build,
`/login`, and `/model`.

`OpenAICompatibleModelPort` additionally accepts an optional
`request_headers` hook that is evaluated before every HTTP request and whose
entries override the defaults, and a `send_prompt_cache_key` opt-in
(default off) that derives `posoco-<session-id>` onto the wire; if the
provider's error body explicitly rejects the parameter, the port stops
sending it for the rest of the process.

## Settings contract

`.cetas/settings.json`:

```json
{
  "providers": {
    "qwen": {
      "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
      "model": "qwen-plus",
      "api_key": "sk-...",
      "reasoning_effort": ["low", "medium", "high"]
    },
    "relay": {
      "base_url": "https://example.com/v1",
      "api_key": "sk-...",
      "models": [
        {
          "id": "qwen3-max",
          "context_window": 262144,
          "compact_threshold": 0.85,
          "reasoning_effort": ["low", "high"]
        },
        { "id": "qwen3-flash", "context_window": 131072 }
      ]
    }
  }
}
```

| Field | Required | Meaning |
|---|---|---|
| `base_url` | yes | Full endpoint (a `/v1`-suffixed URL works as-is) |
| `model` | yes* | Model id (flat single-model form; mutually exclusive with `models`) |
| `models` | yes* | Multi-model array, see below; each entry becomes one slot (`<provider>/<model id>`) selectable via `/model` |
| `api_key` | no | Also injectable via `/login <id>`; persisted to `~/.cetas/credentials/<id>.json` |
| `endpoint_prefix` | no | Default empty; set `/v1` only when `base_url` is a bare host |
| `reasoning_effort` | no | Array (canonical): declares the selectable levels. String (legacy): one fixed level, equivalent to `[that value]` used as the default. Legacy toggles `off`/`on` mean "omit the field" (see below) |
| `reasoning_efforts` | no | Plural alias of the array form; declaring both with different lists is a composition failure |
| `image_input` | no | Boolean; opts the model into typed image content parts instead of placeholder downgrade |

\* `model` and `models` are two styles per provider: combining them — or
combining `models` with provider-level `reasoning_effort`/`reasoning_efforts`
— is a composition failure. Missing `api_key`, `base_url`, or `model` is a
normal Unconfigured state (no slot), not an error.

### `models[]` entry fields

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Model id; must be unique within the provider |
| `context_window` | no | Positive integer, token capacity. Absent = unknown, and auto-compact stays off for that model (no default window is guessed) |
| `compact_threshold` | no | Float in (0, 1] (e.g. `0.85`): auto-compact trigger as a fraction of the window; out of range is a composition failure. Requires `context_window`. Absent = the **0.88** core default applies |
| `reasoning_effort` / `reasoning_efforts` | no | Same semantics as the provider-level keys, scoped to this model |

`context_window` / `compact_threshold` cross the ModelPort seam via the
slot's `provider_config()`; the Agent builds each turn's RunPolicy with the
priority **host explicit config > provider report > core default 0.88**.
When auto-compact triggers, the port makes one summarize call (no
`reasoning_effort`, no tools) and replaces the transcript with the summary
(mode `Replace`, one user message).

### Reasoning effort semantics

The request surface follows standard Chat Completions: the only reasoning
control is the top-level `reasoning_effort` string, sent verbatim. There is
no vendor `thinking` object, and reasoning text is never echoed on outbound
messages — vendor wire dialects belong to vendor extensions.

- **No levels declared**: no reasoning selector at all — `reasoning_effort`
  is never sent and the endpoint applies its own default. Conventional sets
  like `low/medium/high` are never fabricated, and there is no "force
  thinking on" field.
- **Array declared** (e.g. `["low", "max"]`): the selector is `off` plus each
  declared value. Selecting `low` sends top-level
  `reasoning_effort: "low"`. The default level is the first array entry.
- **`off`**: the field is omitted entirely.
- Legacy stored settings with `reasoning_effort: "on"` keep composing but map
  to omission (wire-identical to `off`); `on` fails composition once explicit
  levels are declared.
- `off` / `on` are reserved selector words and must not appear in a declared
  array; entries must be non-empty, unique strings.

### Wire notes

- Streaming requests carry `stream_options: {"include_usage": true}`;
  `max_output_tokens` maps to the standard `max_tokens` field for compatible
  servers.
- Endpoints that return thinking text under the vendor `reasoning` key are
  not decoded — only the standard `reasoning_content` surfaces — so thinking
  will not display there (body and tool calls are unaffected).
- Gateways that silently strip parameters they do not list will therefore
  report no streaming usage; non-streaming usage is unaffected.

### HTTP failures

- A non-2xx body is carried verbatim into the error message (capped at 2048
  chars), so a 400 shows the provider's own rejection reason.
- A 429 becomes the typed `RateLimited` error, parsed for a stated reset time
  (`resets_at` / `resets_in_seconds`, `retry_after`, or a timestamp inside
  the message text).
- An in-stream `{"error": ...}` payload classifies as
  `Transport (stage=error, category=provider_error)` with enum-like
  `error_type=` / `error_code=` labels extracted when present; free-text
  fields from that path never enter the error message.
- A marker-less stream EOF is an error unless every accumulated tool call is
  complete (id/name/parseable arguments); a cut text-only answer never passes
  as complete.

## Debugging: wire log (js/bun)

Set `POSOCO_WIRE_LOG` to a file path and streaming requests append **every
raw SSE data payload**, one per line, to that file (js/bun only; native is a
no-op — see `src/wire_log_native.mbt`). The file bypasses the TUI; append
failures are swallowed and can never break a turn.

```bash
POSOCO_WIRE_LOG=~/.cetas/wire.log bun run start
```

The file contains full provider traffic (streamed content, error payloads in
full) — local debugging only.

## Boundaries

- **This extension**: the standard Chat Completions protocol plus one
  provider id. Nothing else.
- **`posoco-ext-llm`**: catalog aggregation and the `/model` command,
  provider-neutral forever.
- **`cetas-core`**: routes settings ids unclaimed by static factories to this
  extension — the single policy landing point, and vendor-neutral.
- **`cetas-js`**: host-owned process caches and file IO; it never knows a
  custom provider's name.

Custom slots share the `custom` display group, so the host picker tabs them
together with no host-side changes.

## Dependencies

- `colmugx/posoco` — ModelPort trait + types
- `colmugx/posoco-devkit` — `ExtContext` logger helper
- `colmugx/posoco-ext-llm` — provider-neutral catalog/router
- `colmugx/posoco-ext-oauth` — `ApiKeyCredential` / `AuthPromptInteraction`
- `colmugx/posoco-kit-chat-completions` — shared SSE parsing, 429
  classification, content encoding, and `prompt_cache_key` helpers
- `moonbitlang/async/http` — HTTP transport
