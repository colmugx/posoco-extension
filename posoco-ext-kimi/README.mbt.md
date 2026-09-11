# posoco-ext-kimi

> **Targets: native + js** — depends on `moonbitlang/async/http`.
> wasm-gc is not in the supported matrix.

A deeply Kimi-tuned [`ModelPort`](https://mooncakes.io/docs/colmugx/posoco)
implementation for Posoco. You pick one model id; the provider owns thinking,
tool calls, effort capabilities, OAuth, and HTTP error handling — over Kimi's
native OpenAI **Responses** wire (`POST {origin}{prefix}/responses`) on both
hosts: the Moonshot Open Platform (API key) and the managed coding endpoint
(OAuth token).

## Ports contributed

Three structs, one layer each:

| Struct | Port | Responsibility |
|--------|------|----------------|
| `KimiModelPort` | `ModelPort` / `Extension` | chat and streaming chat over the Responses wire; composes into `Agent(exts=[...])` as a model extension |
| `KimiProvider` | `llm.ApiKeyFactory` / `OAuthFactory` / `ProviderFactory` / `RefreshableProviderFactory` | host-side provider registration: builds ports from generic settings/secret sources, performs device-flow login, and refreshes the catalog from an authenticated `/models` response |
| `KimiOAuth` | `oauth.OAuthProvider` | RFC 8628 device flow for the Kimi Code subscription |
| `KimiUsageSource` | `devkit.QuotaSource` | pull-style `/usages` quota probe for the managed subscription (registered automatically by the factory) |

## Usage

```bash
moon add colmugx/posoco-ext-kimi
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-kimi" @kimi

let config = @kimi.KimiConfig(
  api_key="sk-...",
  model="kimi-k3", // default; may be omitted
)
let port = @kimi.KimiModelPort(config)
let catalog = port.model_catalog()
let router = @llm.RouterModelPort::from_catalogs(catalogs=[catalog])

// RouterModelPort is itself an Extension — compose it as the Agent's model.
let agent = @posoco.Agent(exts=[router, ..other_extensions], config~)
```

Hosts can also take the factory path (what cetas does): register
`KimiProvider(ctx~) as &@llm.ProviderFactory` in the factory list, and
settings, login, and catalog refresh all reuse the same seam. Hosts that
persist a device id across runs pass it at construction
(`KimiProvider(ctx~, device_id~)`); only OAuth (managed `/coding`) requests
carry the resulting identity headers. The OAuth credential path builds configs
through `KimiConfig::from_oauth_credential`.

## The Responses wire

Both request paths (non-streaming and SSE) speak one protocol, with the
wire-generic items/SSE machinery living in `posoco-kit-responses`:

- System messages never enter `input`; they are lifted into the top-level
  `instructions` field (joined with `\n\n` when several).
- Every request is a stateless full replay: no `store`, no
  `previous_response_id`. Assistant reasoning items ride home inside
  `Reasoning.raw` and are replayed verbatim, which keeps the request prefix
  byte-stable for cache hits.
- Sampling knobs (`temperature`, `top_p`), `tool_choice`, `search_context_size`,
  and `blocked_domains` are never serialized — Kimi documents 400s for them.
- Tool call ids are sanitized to `[a-zA-Z0-9_-]` and 64 chars max, on both
  `function_call` and `function_call_output` items.
- `max_output_tokens` passes through; an `incomplete` response with that reason
  maps to `FinishReason::Length`, not a protocol failure.

API-key mode uses the Moonshot Open Platform `https://api.moonshot.ai/v1`
(configurable `base_url` + `endpoint_prefix`); OAuth mode uses
`https://api.kimi.com/coding/v1`.

## Model policy

Kimi speaks the Responses wire for the k3-era model families only. Supported
ids prefix-match `kimi-k3`, `k3`, or `kimi-for-coding`. Every pre-k3 id
(`kimi-k2.*`, `moonshot-v1-*`, `kimi-latest`, ...) was removed with its line:
constructing a `KimiConfig` with one aborts with the migration pointer
(`kimi_model_policy_error`) instead of producing a mysterious provider
400/404. Live discovery is filtered through the same allowlist, and the
platform default is `kimi-k3` while the OAuth branch of build/refresh defaults
to `k3-256k`.

## Reasoning and prompt caching

- **Effort** — k3-era models reason always and expose `low` / `high` / `max`
  through `reasoning: {"effort": ...}`, the only reasoning knob. The API
  default is `max`; the configured default stays cost-sane at `high`. The
  effort is validated in the config constructor (abort) and again as a typed
  `CompositionError` at catalog rebuild — no implicit fallback. An empty
  effort string (a refresh still resolving) suppresses the field.
- **`prompt_cache_key`** — sent by default (Moonshot defines the parameter
  natively), derived from the invocation scope's session id. Hosts opt out
  with `send_prompt_cache_key=false`; if the server's error body explicitly
  rejects the parameter, the port stops sending it for the rest of its
  process lifetime.

## Provider capabilities

The model catalog advertises `chat`, `streaming`, `reasoning`, `api_key`, and
`oauth`. It intentionally does **not** advertise FIM, prefix completion, or
video input. Discovery (`/models`) reports each model's context window, effort
list, default effort, and an `image_in` capability when the model accepts
images (image blocks serialize as `input_image` data URLs).

## Kimi-specific tuning

| Feature | Implementation |
|---|---|
| **Streaming** | one SSE loop; every `data:` line is delegated to the kit parser, which owns accumulation and pushes each chunk exactly once — reasoning summary deltas surface once each as `StreamChunk::ReasoningDelta` |
| **Compact** | no compact endpoint; one extra non-streaming Responses call summarizes everything older than the last two user/assistant messages (structured XML template), with no tools and no reasoning override |
| **Context window** | reported by the `/models` discovery endpoint; `None` = unknown, auto-compact stays off rather than guessing; the provider-config trigger ratio is kimi-cli's 0.85 |
| **HTTP errors** | 429/403 quota verdicts keep the body and honor `Retry-After`; 401 names the platform/coding credential mismatch; a 400 payload over the coding host's 2 MiB message cap fails loudly with the limit named |
| **API key** | `KimiProvider` implements `@llm.ApiKeyFactory`; hosts supply only a generic secret prompt/store |

Hosts may call provider-owned `RefreshableProviderFactory::refresh` during
explicit startup or login to update model order, context windows,
capabilities, and effort metadata from the authenticated `/models` response.
The configured model id keeps priority in the refreshed result; request
timeouts, non-2xx statuses, malformed JSON, and empty catalogs are all typed
failures with no implicit fallback to the old catalog. If the server declares
reasoning without a concrete effort list, the slot keeps the `reasoning`
capability but exposes no effort rebuild hook.

## OAuth details

Device responses accept only absolute `http`/`https` verification URIs and
non-empty required fields. Token lifetimes must be finite positive integers;
refresh retries only transient 429/5xx responses (at most three retries with
1s/2s/4s backoff) and reports redacted status/body-length diagnostics on
terminal failure. The shared OAuth transport enforces a 30-second request
deadline and can be replaced by a deterministic fake in tests.

## Kimi For Coding usage

OAuth (managed subscription) mode also exposes a pull-style quota source:
`KimiUsageSource` implements `@devkit.QuotaSource` against
`GET {base}/usages` on `https://api.kimi.com/coding/v1` (10s timeout,
`Authorization: Bearer` + `Accept: application/json`). It parses the weekly
summary (`usage`) and windowed limits (`limits[]`; the 300-minute window is
labeled `5h`, other duration/timeUnit pairs keep their raw values verbatim),
matching the codex subscription display: window-remaining readings only. The
`boosterWallet` field is intentionally ignored and produces no `balance`
reading. All decimal fields accept both string and number wire
forms; rows missing their used/limit pair are skipped rather
than estimated.

The provider factory registers the source under the id `"kimi"` on every
configured `build`/`refresh` that takes the OAuth branch (last write wins),
so hosts that render the `/status` quota section pick it up with no extra
wiring. API-key mode (the Moonshot Open Platform, `api.moonshot.ai`) has no
`/usages` endpoint and never registers.

## What was removed

- The chat-completions wire and its knobs: the `thinking` object, k2-era
  effort spellings, and `reasoning_content` replay policy are gone —
  `reasoning.effort` and raw item replay replace them.
- The k2 model line: `kimi-k2.*`, `moonshot-v1-*`, and `kimi-latest` ids fail
  construction with the migration pointer (see [Model policy](#model-policy)).
- The `supports_images` config flag: image support now follows discovery's
  `image_in` capability.

## Dependencies

- `colmugx/posoco` — ModelPort trait + types
- `colmugx/posoco-devkit` — `ExtContext` logger helper + quota registry
- `colmugx/posoco-ext-llm` — provider-neutral catalog/router
- `colmugx/posoco-ext-oauth` — OAuth provider contract and credential store
- `colmugx/posoco-kit-responses` — OpenAI Responses wire kit (items, SSE,
  termination classification)
- `colmugx/posoco-kit-chat-completions` — HTTP error classification and
  `prompt_cache_key` helpers reused from the shared kit
- `colmugx/posoco-kit-compact-summary` — structured summary template for compact
- `moonbitlang/async/http` — HTTP transport
