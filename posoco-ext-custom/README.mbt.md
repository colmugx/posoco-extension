# posoco-ext-custom

> **Targets: native + wasm + js** — the transports depend on
> `moonbitlang/async/http`. Config, protocol vocabulary, the chat-wire codec,
> the responses/messages request shapes, header construction, failure
> classification, the catalog/factory, and all pure tests compile everywhere;
> only the wire transports are gated to the targets that have HTTP.

The custom-provider extension for [Posoco](https://github.com/colmugx/posoco):
one settings-declared endpoint, served on one of three wires.

A custom provider is what an entry in `.cetas/settings.json` under `providers`
means when the id is not claimed by a static provider. The extension owns the
whole feature — settings interpretation, catalog, credential placement, wire
selection, transport, and API-key login — and the host owns exactly one policy:
which id falls through to it.

| Wire (`protocol`) | Request | Kit |
|---|---|---|
| `chat_completions` (default) | `POST {base_url}{endpoint_prefix}/chat/completions` | `posoco-kit-chat-completions` |
| `responses` | `POST {base_url}{endpoint_prefix}/responses` | `colmugx/posoco-kit-responses` |
| `messages` | `POST {base_url}{endpoint_prefix}/messages` | `colmugx/posoco-kit-messages` |

## Ports contributed

| Struct | Port | Responsibility |
|--------|------|----------------|
| `CustomModelPort` | `ModelPort` | `chat`/streaming on the declared wire, plus a summarize-based compact that runs through the same wire; reports `context_window` / `compact_threshold` to the Agent's auto-compact policy |
| `CustomProvider` | `llm.ProviderFactory` / `llm.ApiKeyFactory` | builds the catalog for its one provider id from an opaque settings/credential source, and owns the API-key login prompt |

The extension implements **no** `Extension::manifest` and never composes as a
top-level extension: it participates through cetas-core's factory registry, the
same shape as the deepseek/kimi/openai provider extensions. It never reads the
host's settings map itself and never decides which ids it serves — the host
hands it an opaque `ProviderConfigSource` for one id.

## Usage

```bash
moon add colmugx/posoco-ext-custom
```

```moonbit nocheck
// moon.pkg: "colmugx/posoco-ext-custom" @custom
//            (+ "posoco/ext-llm" @llm for the router)

let config = @custom.CustomConfig(
  "sk-...",
  base_url="https://api.anthropic.com",
  endpoint_prefix="/v1",
  model="claude-sonnet-5",
  protocol=@custom.CustomProtocol::Messages,
)
let port = @custom.CustomModelPort("claude-proxy", config)
let catalog = port.model_catalog()
let router = @llm.RouterModelPort::from_catalogs(catalogs=[catalog])
```

Hosts take the factory path (what cetas does): cetas-core's
`compatible_provider_factories(settings, ctx)` mints one `CustomProvider` per
settings id not claimed by a static provider, so custom ids participate
identically to static ones in catalog build, `/login`, and `/model`.

`CustomModelPort` also accepts an optional `request_headers` hook evaluated
before every HTTP request whose entries override the defaults, so a host can add
routing or identity headers without this extension learning their names.

## Settings contract

```json
{
  "providers": {
    "my-gateway": {
      "base_url": "https://llm.internal.example/v1",
      "api_key": "sk-...",
      "protocol": "chat_completions",
      "models": [
        { "id": "qwen3-max", "context_window": 262144 },
        { "id": "gpt-x", "protocol": "responses", "context_window": 200000 }
      ]
    }
  }
}
```

| Field | Required | Meaning |
|---|---|---|
| `base_url` | yes | Endpoint origin + version segment (a `/v1`-suffixed URL works as-is) |
| `model` | yes* | Model id (flat single-model form; mutually exclusive with `models`) |
| `models` | yes* | Multi-model array; each entry becomes one slot (`<provider>/<model id>`) |
| `protocol` | no | `chat_completions` (default), `responses`, or `messages`; `models[]` entries may override it |
| `auth` | no | `auto` (default), `bearer`, `x_api_key` — where the key rides |
| `max_output_tokens` | no | Positive integer, default `8192`; the `max_tokens` value the `messages` wire requires |
| `api_key` | no | Also injectable via `/login <id>`; persisted to `~/.cetas/credentials/<id>.json` |
| `endpoint_prefix` | no | Default empty; set `/v1` only when `base_url` is a bare host |
| `reasoning_effort` / `reasoning_efforts` | no | Declared selectable levels (array) or one fixed level (string, legacy) |
| `image_input` | no | Boolean; opts the model into native image content instead of a placeholder |
| `send_prompt_cache_key` | no | Chat-completions only: derive `posoco-<session>` onto the wire, with 400-learning when the endpoint rejects it |

\* `model` and `models` are two styles per provider: combining them — or
combining `models` with a provider-level `reasoning_effort`/`reasoning_efforts`
— is a composition failure. Missing `api_key`, `base_url`, or `model` is a
normal `Unconfigured` state (no slot), not an error.

### `models[]` entry fields

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Model id; unique within the provider |
| `protocol` | no | Per-model override of the provider's wire |
| `context_window` | no | Positive integer token capacity. Absent = unknown, and auto-compact stays off for that model (no window is guessed) |
| `compact_threshold` | no | Float in (0, 1]; requires `context_window` |
| `reasoning_effort` / `reasoning_efforts` | no | Same semantics as the provider-level keys, scoped to this model |
| `image_input` | no | Boolean, scoped to this model |

### Credential placement

| `auth` | `chat_completions` / `responses` | `messages` |
|---|---|---|
| `auto` | `Authorization: Bearer <key>` | `x-api-key: <key>` + `anthropic-version: 2023-06-01` |
| `bearer` | `Authorization: Bearer <key>` | `Authorization: Bearer <key>` + `anthropic-version` |
| `x_api_key` | `x-api-key: <key>` | `x-api-key: <key>` + `anthropic-version` |

### Reasoning levels per wire

Level names are the user's vocabulary, sent where the wire expects them. No
token budget is fabricated:

- `chat_completions` — top-level `reasoning_effort`, sent verbatim.
- `responses` — `reasoning.effort`; temperature is dropped when a level is
  selected (reasoning endpoints reject it with 400).
- `messages` — `thinking: {"type": "enabled"}` with no `budget_tokens`.
- `off` — nothing is sent on any wire.

The `responses` wire runs stateless (`store: false`) and does not replay
reasoning items: a generic endpoint declares no encrypted-reasoning contract, so
nothing is echoed back. Reasoning *display* still works — the kits surface
summaries and thinking text when the endpoint sends them.

### Compact

No wire exposes a dedicated compact endpoint, so compaction is
client-orchestrated: render the transcript, ask the model for a dense handoff
summary in one non-streaming call on the **same** wire (no reasoning surface, no
tools), then replace the transcript with that summary (`Replace`, one user
message).

## Debugging: wire log (js/bun)

Set `POSOCO_WIRE_LOG` to a file path and every wire appends its raw SSE data
payloads, one per line (js/bun only; native is a no-op). The file contains full
provider traffic — local debugging only.

```bash
POSOCO_WIRE_LOG=~/.cetas/wire.log bun run start
```

## Boundaries

- **This extension**: one declared endpoint, the three standard wires, one
  provider id. Nothing else.
- **`posoco-ext-llm`**: catalog aggregation and the `/model` command,
  provider-neutral forever.
- **`cetas-core`**: routes settings ids unclaimed by static factories here —
  the single policy landing point, and protocol-neutral.
- **`cetas-js` / hosts**: process caches and file IO; they never learn a custom
  provider's name or protocol.

Custom slots share the `custom` display group, so the host picker tabs them
together with no host-side changes.

## Dependencies

- `colmugx/posoco` — `ModelPort` trait + types
- `posoco/devkit` — `ExtContext` logger helper
- `posoco/ext-llm` — provider-neutral catalog/router
- `posoco/ext-oauth` — `ApiKeyCredential` / `AuthPromptInteraction`
- `posoco/kit-chat-completions` — SSE parsing, content encoding, prompt-cache
  and transient helpers
- `colmugx/posoco-kit-responses` — Responses items, tools, SSE, termination
- `colmugx/posoco-kit-messages` — Messages blocks, request encoder, SSE events
- `colmugx/posoco-kit-rate-limit` — 429 classification
- `moonbitlang/async/http` — HTTP transport
