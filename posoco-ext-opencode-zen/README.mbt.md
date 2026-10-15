# posoco-ext-opencode-zen

> **Targets: native + js** — depends on `moonbitlang/async/http`. wasm-gc is
> not in the supported matrix.

A named [`ProviderFactory`](https://mooncakes.io/docs/colmugx/posoco) for the
OpenCode **Console** gateway (pay-as-you-go, formerly "Zen"). The gateway
serves each model on its upstream's **native wire** — OpenAI Chat
Completions, OpenAI Responses, Anthropic Messages — behind one API key. This
extension publishes the catalog as the `opencode` provider, so
`/login opencode` and `/model` work out of the box, and dispatches every
model to the wire it is actually served on.

This package is also the **shared base** for `posoco-ext-opencode-go`: the
wire ports, protocol derivation, models.dev metadata, identity headers,
anchored compact, and spend accounting all live here.

## Ports contributed

| Struct | Port | Responsibility |
|--------|------|----------------|
| `OpenCodeZenModelPort` | `ModelPort` | chat and streaming chat, dispatched per model over the Chat Completions / Responses / Messages wires; reports `context_window` / `compact_threshold` to the Agent's auto-compact policy |
| `OpenCodeZenProvider` | `llm.ProviderFactory` | static `build`: a no-network catalog over the resolved credential/endpoint/model (expanded offline from host-cached records when available) |
| `OpenCodeZenProvider` | `llm.RefreshableProviderFactory` | live `refresh`: one authenticated `/models` call, one slot per discovered model, enriched from the models.dev mirror |
| `OpenCodeZenProvider` | `llm.ApiKeyFactory` | the `/login opencode` secret prompt |
| `ZenSpendTracker` / `ZenSpendQuotaSource` | devkit quota/status | per-session spend estimate pushed to the `spent` statusbar segment; pull-style `spend(...)` readings under the provider id |

The extension implements **no** `Extension::manifest`: it is a
factory-registered provider, composed indirectly through cetas-core's factory
registry (same shape as deepseek/kimi and the other named providers), never
held as a top-level extension by the Agent. Slots wrap the port in the
router-level transient-retry decorator (`posoco-ext-llm`).

## Usage

```bash
moon add colmugx/posoco-ext-opencode-zen
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-opencode-zen" @opencode_zen
//            (+ "posoco/ext-llm" @llm for the router)

let provider = @opencode_zen.OpenCodeZenProvider()
let config = @opencode_zen.OpenCodeZenConfig(
  "sk-zen-...",
  base_url="https://opencode.ai/inference/v1",
  model="claude-sonnet-5",
)
let catalog = @opencode_zen.zen_static_catalog(config, provider)
let router = @llm.RouterModelPort::from_catalogs(catalogs=[catalog])

// RouterModelPort is itself an Extension — compose it as the Agent's model.
let agent = @posoco.Agent(exts=[router, ..other_extensions], config~)
```

Hosts can also take the factory path (what cetas does): register
`OpenCodeZenProvider(ctx~)` in the `ProviderFactory`, `ApiKeyFactory`, and
`RefreshableProviderFactory` lists, and settings, `/login opencode`, and
catalog refresh all reuse the same seam.

## The wires: per-model protocol dispatch

The gateway answers `400 ModelProtocolUnsupported` when a model is sent to a
wire it is not served on, and never falls back — so the wire is derived per
model, never stored. Precedence:

1. **Settings override** — `protocol_overrides` (below).
2. **In-code table** — distilled from the vendor's endpoints table
   (`qwen3.8-max` and `mistral-large-4` are chat completions here).
3. **models.dev SDK signal** — the `opencode` entry's per-model
   `provider.npm`: `@ai-sdk/openai` → Responses, `@ai-sdk/anthropic` →
   Messages, `@ai-sdk/google` → Google (unserved), absent → default.
4. **Family fallback** — `claude-*` → Messages, `gpt-/grok-/muse-*` →
   Responses, `qwen*` → Messages, `gemini-*` → Google, `jev-*` → SystemOne.
5. **Gateway default** — Chat Completions.

Models resolving to an **unserved wire** (Google Generative AI, Jev
SystemOne, the Mistral dialect) are excluded from the catalog rather than
offered on a wire that would fail; a hand-built config raises a typed
`wire_not_served` error. A gateway `FreeTierError` (the free tier refuses
every credential a request can carry) and `ModelProtocolUnsupported` both
surface as typed transport markers, never generic failures.

Each wire owns its dialect:

- **Chat Completions** — GLM-flavored for `glm-*` (`thinking:
  {"type": "enabled"}`, verbatim top-level `reasoning_effort`,
  `reasoning_content` echo keep-all, `stream_options.include_usage` always
  on); standard OpenAI shape for the other completions models (no `thinking`
  object, `reasoning_effort` only when a level is selected).
- **Messages** (`posoco-kit-messages`) — `x-api-key` +
  `anthropic-version: 2023-06-01`; effort levels map onto `thinking`
  budget tokens (`none`/`off` disable, the bare `on` toggle uses the
  default budget); `max_output_tokens` (settings-overridable, default
  32768) carries the required `max_tokens`.
- **Responses** (`posoco-kit-responses`) — base-instruction system items
  lift into `instructions`; stateless (`store:false`) full-window replay; a
  level becomes `reasoning.effort` (+ encrypted-content inclusion,
  temperature stripped); reasoning items ride the transcript for replay.

Only the SSE line parsing, 429 classification, and content-encoding helpers
are shared with the other chat-completions providers (via
`posoco-kit-chat-completions`); every dialect spelling lives in this package.

## Metadata, spend, and quota

Live refresh enriches each slot from the models.dev mirror (the same catalog
OpenCode itself reads): reasoning surfaces (the effort picker), `limit.context`
(declared window — auto-compact stays off without one, never guessed),
`attachment` (image input), `provider.npm` (the wire signal), and `cost`
(USD per 1M tokens, context-tiered). The host cache carries the previous
refresh's picker, window, and image facts for offline rebuilds; the wire is
never cached — it re-derives from the table.

With rates known, every settled call records a **spend estimate**
(uncached/cached/output against the model's rates) into a per-session
tracker and publishes the cumulative total as the statusbar `spent` segment
(via the process default status bus). The pull-style quota reading under the
provider id states `spend(<session>)` amounts. **No balance is ever
fabricated**: OpenCode exposes the real balance only through the console's
browser session, so the console is where the authoritative number lives.

## Settings contract

`.cetas/settings.json` — all keys optional, Console has conventional
defaults:

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
| `base_url` | no | `https://opencode.ai/inference/v1` | Override only for private/mirror deployments; the legacy `https://opencode.ai/zen/v1` spelling keeps working (same gateway) |
| `protocol_overrides` | no | — | `{model_id: wire_id}` map (`chat_completions`, `messages`, `responses`, `google_genai`, `system_one`, `mistral`); wins over every table — the escape hatch when the gateway moves a model before the table catches up. Unknown wire ids are typed composition failures |

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
  gateway flakiness. If the host cached records from a previous refresh,
  `build` expands them offline into the full multi-slot catalog (wire
  re-derived from the table); malformed caches degrade to the single static
  slot.
- **Refresh** (`/model refresh` or capability discovery): one authenticated
  `GET /models` (30s timeout). The listing is publicly readable today, but
  the request still carries `Authorization: Bearer` so it keeps working if
  the gateway later gates discovery. The models.dev metadata fetch is
  best-effort: any failure degrades to the `off`/`on` fallback picker per
  model and never fails the refresh. The configured model is pinned first;
  the rest keep server order. `/models` transport, schema, or HTTP failures
  — including an empty list — are typed composition failures; this path
  never falls back to the static catalog.
- Slot ids are `opencode/<bare-model-id>` (e.g. `opencode/claude-opus-5`) —
  the gateway's ids are bare, without the `opencode/` prefix — and
  `display_group="zen"` tabs them together in the picker.

Every request carries OpenCode routing headers: `x-opencode-project` and
`x-opencode-client` set to the product (`opencode-zen`), a process-stable
`x-opencode-session`, and a fresh `x-opencode-request` per request
(`User-Agent: posoco/opencode-zen`). This mirrors the sticky-session
behavior of the OpenCode client while honestly identifying posoco.

## Compact

No compact endpoint exists, so every wire compacts locally with an
OpenCode-style anchored summary: a keep-recent budget of
`clamp(2000..15000, 25% of usable)` where usable is the model window minus a
20k compaction reserve (15k ceiling when no window is known — a window is
never guessed), the previous anchored summary folded into the update prompt,
and one non-streaming summary call with an empty toolset. The summary plus
the kept recent messages replace the transcript.

## Retry

Slots wrap the model port in the router-level retry decorator
(`posoco-ext-llm`) for the gateway's transient failure classes: marker-less
EOF truncation, mid-stream connection resets (`stage=read_stream`), and
gateway 503s. At most 3 retries after the first failure, with a 2s initial
delay doubling per retry — the parameters OpenCode's session retry uses. An
EOF that leaves every tool call structurally complete is not an error at
all: the stream validator passes it through directly, so it never enters
retry. Other errors (pre-stream transport failures, other HTTP statuses) are
never retried.

## Boundaries

- **This extension**: Console endpoint conventions, the three wires
  (encode/decode/SSE/error classification per dialect), per-model wire
  derivation, `/models` decoding, models.dev metadata, spend accounting,
  the multi-slot catalog, and the `/login` prompt.
- **`posoco-ext-llm`**: catalog aggregation and the `/model` command,
  provider-neutral forever.
- **`posoco-ext-opencode-go`**: the subscription plane; depends on this
  package's ports, protocol derivation, metadata, and spend machinery.
- **`cetas-core`**: registers `OpenCodeZenProvider` into
  `provider_factories()` — one place — and `/login`, `/model`, and catalog
  refresh follow automatically. It also registers the session bus as the
  process default status bus, which is what carries the `spent` segment.
- **`cetas-js`**: host-owned process caches and file IO; it is unaware this
  provider exists.

## Dependencies

- `colmugx/posoco` — `ModelPort` trait + `ModelError` / `CompositionError` types
- `posoco/devkit` — `ExtContext`, status/quota registries, `QuotaSource`
- `posoco/ext-llm` — `ProviderFactory` / `RefreshableProviderFactory` / `ApiKeyFactory` / `ProviderModelCatalog` / `ModelSlot`
- `posoco/ext-oauth` — `ApiKeyCredential` / `AuthPromptInteraction`
- `posoco/kit-chat-completions` — shared SSE line parsing / 429 classification / content-encoding helpers
- `colmugx/posoco-kit-messages` — Anthropic Messages wire machinery
- `colmugx/posoco-kit-responses` — OpenAI Responses wire machinery
- `colmugx/posoco-kit-rate-limit` — shared quota-verdict classification
- `colmugx/posoco-kit-compact-summary` — anchored summary template, cut selection, and Replace builder
- `moonbitlang/async/http` — `/models`, metadata, and chat transport
