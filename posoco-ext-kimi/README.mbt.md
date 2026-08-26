# posoco-ext-kimi

> **Targets: native + js** — depends on `moonbitlang/async/http`.
> wasm-gc is not in the supported matrix.

A deeply Kimi-tuned [`ModelPort`](https://mooncakes.io/docs/colmugx/posoco)
implementation for Posoco. You pick one model id; the provider owns thinking,
tool calls, effort capabilities, OAuth, and HTTP error handling.

## Ports contributed

Two structs, one layer each:

| Struct | Port | Responsibility |
|--------|------|----------------|
| `KimiModelPort` | `ModelPort` | chat / chat_streaming (standard trait path) |
| `KimiModelPort` | `Extension` | composes into `Agent(exts=[...])` as a model extension |
| `KimiProvider` | `llm.ApiKeyFactory` / `OAuthFactory` / `ProviderFactory` / `RefreshableProviderFactory` | host-side provider registration: builds ports from generic settings/secret sources, performs device-flow login, and refreshes the catalog from an authenticated `/models` response |
| `KimiOAuth` | `oauth.OAuthProvider` | RFC 8628 device flow for the Kimi Code subscription |

## Usage

```bash
moon add colmugx/posoco-ext-kimi
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-kimi" @kimi

let config = @kimi.KimiConfig(
  api_key="sk-...",
  model="kimi-k2.7-code", // default; may be omitted
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

## Kimi-specific tuning

| Feature | Implementation |
|---|---|
| **Context cache** | append-only message ordering keeps the prefix byte-stable |
| **reasoning_content replay rule** | replayed unconditionally on every assistant message, with or without tool_calls (`thinking.keep="all"` policy) — removing it breaks the byte-for-byte longest-prefix cache |
| **reasoning streaming** | each `reasoning_content` delta is surfaced once as `StreamChunk::ReasoningDelta` and accumulated into the final completion's reasoning field |
| **thinking effort** | per-model-family effort tables validate the configured effort in the config constructor (abort) and again as a typed `CompositionError` at catalog rebuild — no implicit fallback |
| **context window** | reported by the `/models` discovery endpoint; `None` = unknown, auto-compact stays off rather than guessing |
| **images** | enabled from discovery (`image_in`); without it image blocks downgrade to explicit placeholders |
| **API key** | `KimiProvider` implements `@llm.ApiKeyFactory`; hosts supply only a generic secret prompt/store |

API-key mode uses the Moonshot Open Platform `https://api.moonshot.ai/v1`
(configurable `base_url` + `endpoint_prefix`); OAuth mode uses
`https://api.kimi.com/coding/v1`.

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

## Dependencies

- `colmugx/posoco` — ModelPort trait + types
- `colmugx/posoco-devkit` — `ExtContext` logger helper
- `colmugx/posoco-ext-llm` — provider-neutral catalog/router
- `colmugx/posoco-ext-oauth` — OAuth provider contract and credential store
- `colmugx/posoco-kit-chat-completions` — OpenAI-compatible chat protocol kit
- `moonbitlang/async/http` — HTTP transport
