# posoco-ext-openai

OpenAI Responses API and Codex OAuth adapters for Posoco.

The public provider factory exposes both API-key and Codex subscription
authentication. Codex OAuth login is browser-only: it runs the shared PKCE
authorization-code flow from `posoco-ext-oauth`. There is no device-code
flow — no verification URI, no user code, nothing to poll.

## Codex browser login

Login is reached through `OpenAIProvider`'s `@llm.OAuthFactory` impl or by
constructing `CodexOAuth` directly; both end in
`CodexOAuth::login(interaction)`. The flow runs on native and js targets:

1. Bind a local callback server on `http://localhost:1455/auth/callback`
   (port 1455 — the official CLI's allow-listed redirect). When 1455 is
   occupied the bind retries on 1457 and the `redirect_uri` port segment is
   rewritten, so the authorize URL and the token exchange always carry the
   identical `redirect_uri`.
2. Generate the PKCE pair and a fresh random state, then hand the authorize
   URL to the host via `AuthMessage::AuthUrl` — opening it in a browser is
   the **host's** responsibility; the extension never launches one.
3. Wait for the callback and validate the returned state against the
   generated one. A mismatch raises before any token-exchange request is
   sent; the wait itself times out after 5 minutes (`ExpiredToken`).
4. POST the code plus verifier to `https://auth.openai.com/oauth/token`.

The authorize URL carries `scope=openid profile email offline_access` plus
the Codex params `originator=posoco` (the same honest identity as the wire
identity section), `id_token_add_organizations=true`, and
`codex_cli_simplified_flow=true`.

Token parsing is strict on both the initial exchange and the refresh (the
shared flow's lenient default parser is overridden): `refresh_token` must be
present and non-empty, `expires_in` must be a finite positive integer
(fractional or non-positive values are rejected), and the access-token JWT
must carry `chatgpt_account_id` nested under `https://api.openai.com/auth` —
a flat dotted key or a missing claim is rejected. The claim value is
persisted as credential metadata and sent as `chatgpt-account-id` on
subscription requests. Every violation is a typed `OAuthError::ParseError`.
OpenAI rotates the refresh token on each refresh; the refreshed credential
always carries the newest one.

`OAuthHttpTransport` stays injectable (`CodexOAuth(transport=...)`) so tests
and hosts can inspect exchange and refresh wire requests without network
access; when omitted, the default transport enforces the 30-second OAuth HTTP
deadline. On wasm targets there is no callback server: `login()` raises a
typed `OAuthError::HttpError`.

## Explicit model refresh

`OpenAIProvider` implements `RefreshableProviderFactory`. The host must call
the refresh seam explicitly; normal provider construction never performs a
network request. API-key credentials use the standard `{data:[{id}]}`
endpoint, while Codex OAuth uses the provider-specific
`/models?client_version=0.159.0` endpoint and `models[]` metadata. Codex
reasoning levels are copied in server order, and hidden or
`supported_in_api=false` records are excluded from selectable slots. The
provider-owned HTTP transport is injectable for deterministic tests. The
standard API envelope is validated as `{object: "list", data: [...]}` before
any model records are accepted; Codex keeps its independent `models[]` schema.

## Codex quota capture and usage reporting

Codex states its authoritative numbers two ways, and both land in one
`CodexQuotaTracker`: on every model response as HTTP headers
(`x-codex-primary-*` for the 5-hour window, `x-codex-secondary-*` for weekly,
`x-codex-credits-*` for the account balance — the same family codex-rs parses),
and through the usage endpoint `GET {backend-api}/wham/usage` (the endpoint
community tooling polls; it answers the windows, plan type, and credits without
spending a model request).

- Every port the provider factory builds — the factory's own port, every
  catalog slot, every credential/effort rebuild — shares the process-wide
  tracker (`codex_shared_quota_tracker()`; one process serves one ChatGPT
  account). Both the streaming and buffered/compact response paths feed it
  **before** the HTTP status branch, so an exhausted 429 still states its
  percentages and reset times. Hosts that prefer isolation construct their own
  tracker and pass it at port construction.
- `CodexQuotaTracker` implements `devkit.QuotaSource`, but `read()` replays the
  **latest snapshot**, not a fresh request. Staleness is explicit via
  `fetched_at_ms`; consumers gate on it (stale → warn-only), and `read()` is
  `Err` until the first capture.
- `refresh` (Codex OAuth branch) probes the usage endpoint best-effort on the
  same transport — the snapshot starts populated without waiting for the first
  chat response. Probe failure is silent; header capture remains the
  authoritative feed.
- Header parsing maps families onto window labels: `primary` → `"5h"`,
  `secondary` → `"weekly"`, credits → `"balance"`
  (`amount = (balance, "credits")`, `available = has-credits`); usage-endpoint
  windows are labeled by their stated duration (`limit_window_seconds` 300
  minutes → `"5h"`, 10080 → `"weekly"`, so a weekly-only plan exposing the
  weekly window in the primary slot still labels correctly).
  `reset-at` states unix seconds and is converted to milliseconds; a window
  with only `reset_after_seconds` anchors to the fetch time. A family without
  `used-percent` (or with malformed numbers) states nothing and is skipped;
  captures without quota data leave the previous snapshot untouched.

### Status-bar publication

`CodexQuotaStatus` turns the tracker into status segments: it observes
`ModelResponseReceived`, and whenever the snapshot changed it publishes the
`5h` and `weekly` windows (`segment` = the window label, priority 45,
`value` = `"<n>% left"` where `n = 100 − used_percent` — the remaining-quota
semantics the codex CLI reports, color `warning` at ≤ 20% left and `error`
at ≤ 0%) through the devkit status protocol. Windows that vanish from the
snapshot are unregistered so a stale percentage never lingers; unchanged
snapshots stay silent. It also implements `Lifecycle`: at `on_compose` an
already-populated snapshot (refresh's usage probe) publishes immediately, so
the bar shows the windows from startup instead of after the first response.
And it implements `devkit.BusSubscriber` for the llm router's provider
events (`topic = "provider"`, `data.provider_id`): while another provider is
active the published windows are unregistered and kept unpublished, and they
reappear (as `% left` again) when codex re-activates; hosts without a router
publishing provider events never see the windows hide. With `bus = None`
everything is a no-op.

```moonbit nocheck
// host wiring (cetas-js does exactly this):
let codex_quota = @openai.CodexQuotaStatus(bus=Some(event_bus))
// segments appear on the shared status bar at composition when the usage
// probe already captured a snapshot, else after the first Codex response,
// e.g.: 5h 55% left  weekly 20% left
```

## Intelligence metrics

The extension owns the codex-reset-radar intelligence feed:
`GET https://codex-reset-radar.pages.dev/api/intelligence-efficiency-metrics?refresh=1`
(credential-free, carried by the shared models transport's 5 s timeout).
`parse_intelligence_metrics` is strict about types and lenient about
absence — of the eight consumed fields, six (`model`, `effort`, `iq`,
`average_price_usd`, `passed`, `total`) must be well typed when stated, and
two (`average_total_tokens`, `average_minutes`, mapped to the point's
`tokens`/`minutes`) are optional (number → carried, absent or null →
omitted — the feed drops them on some entries); entries whose consumed
fields the source has not stated yet (null or absent — placeholder rows for
models still being measured) are skipped, while wrong-typed values still
fail the whole parse; the feed's other vendor fields (including deepseek's
price bands) are ignored, and non-OpenAI models pass through unfiltered
(slot intersection is the consumer's job). `intelligence_metrics_source()` returns the devkit
`ModelMetricsSource` that fetches and parses on every read; both factory
`build` and every configured `refresh` register it under `"openai"` (last
write wins), so the `/model openai pick` command always reads through the
latest registration (`src/intelligence_metrics.mbt`, registration at
`src/provider_factory.mbt:52-57`).

## Usage and cache accounting

Both response paths report `usage` on the completion and as a `Usage` stream
chunk at `response.completed`: `input_tokens`, `output_tokens`,
`total_tokens`, and `cached_input_tokens` from
`input_tokens_details.cached_tokens`. The provider reports the cache **hit**
share only, so `uncached_input_tokens` stays `None` (the shared Usage contract:
only providers that natively report hit-and-miss pairs fill it); consumers
derive the hit rate as `cached_input_tokens / input_tokens` — which is what
the llm router's `cache` status segment and posoco-ext-stats already render.

## Session compaction

Compaction goes through the official standalone endpoint
(`POST /responses/compact`, `src/posoco_ext_openai.mbt:820-849`): the full
current window is sent as `input` items and the response's `output` array is
the canonical next window, committed as `CompactMode::Replace` — the
endpoint is stateless and ZDR-friendly, and the opaque compaction item
replays verbatim on subsequent chat calls. The response envelope is
validated before anything is accepted (`src/posoco_ext_openai.mbt:770-817`):

- A JSON `error` object in the envelope is a terminal
  `category=provider_error` failure.
- Missing or `null` `output` is a hard `ResponseParse` failure
  (`category=missing_output`) — never decoded as an empty window, which
  would wipe the session and report success.
- A non-array `output` fails as `category=wrong_type`; a non-object
  envelope as `category=not_object`.
- An empty window for a non-empty session fails as `category=empty_window`
  (an already-empty session may compact to an empty window).
- Mixed windows — compaction item, user, reasoning, function call and
  output, assistant text — roundtrip verbatim and in order; unknown but
  legal wire items pass through untouched (tests `openai_compact_*`,
  `src/posoco_ext_openai_wbtest.mbt:1334-1454`).

## Request shaping

`base_url` is split at client construction into a client origin and an endpoint
path prefix: `@http.Client` only accepts `scheme://host[:port]`, while request
paths are host-relative. So `https://api.openai.com/v1` connects to
`https://api.openai.com` and prefixes every endpoint path with `/v1` (trailing
slashes are not part of the prefix; a scheme-less base_url is a typed transport
error). Requests that carry a reasoning effort (the Codex / gpt-5 family) never
send `temperature` — the backend rejects it with 400
`{"detail":"Unsupported parameter: temperature"}` — while plain models keep the
`ChatOptions` passthrough.

## Streaming wire contract

The Codex backend interleaves non-tool output items, so the SSE parser maps each
wire `output_index` onto a compact tool-call slot (the accumulator contract
requires a contiguous 0-based sequence over tool calls; an effort-tuned first
function_call typically sits at `output_index` 1 behind a reasoning item).
`response.output_item.done` is parsed alongside `added`: it backstops
function-call identity (call_id falls back to the item id) and is the only place
a reasoning item is complete — its `encrypted_content` grows during the stream,
so done replaces the added snapshot and the raw item is captured verbatim for
replay on the next request. The terminal `response.completed` event carries an
empty `output` array on Codex, so the finish reason is derived from the
accumulated tool calls (streamed tool calls are the authoritative `tool_calls`
signal), and the Finish chunk uses the wire spelling (`stop`/`tool_calls`) that
the completion parser understands.

Reasoning streams through the official event vocabulary: summary text arrives
as `response.reasoning_summary_text.delta` (parts separated by a blank line on
`response.reasoning_summary_part.done`), raw reasoning text as
`response.reasoning_text.delta` — all mapped onto the single `ReasoningDelta`
chunk. Requests carrying a reasoning effort ask for `summary: "auto"` plus
`reasoning.encrypted_content`; when the backend emits no summary, the done
reasoning item's `content[]` reasoning text is the visible-text fallback (the
same order codex-rs and pi resolve it).

## HTTP failure classification

Every 429 is a quota verdict, not a transport failure: the response body is
classified by the shared chat-completions kit
(`classify_chat_completions_http_error` — nested `error.code`/`type`,
`resets_in_seconds`, `resets_at`, `retry-after`) and raised as the typed
`ModelError::RateLimited`, which is what `RateLimitGuard`-style hosts match to
schedule recovery and publish resume status. A 429 with an empty or undecodable
body still raises `RateLimited` with `reset_at_ms = None` (probe backoff is the
designed handler). Every other non-2xx status stays a `Transport` error
carrying status, body-size metadata, and a bounded excerpt of the decoded body
— trimmed, whitespace-collapsed, and hard-capped at 240 chars, rendered as
`body_excerpt="..."` — so provider validation errors name the offending
request item. The full response payload never crosses the error boundary;
undecodable or unreadable bodies carry no excerpt.

Cancellation during a stream — the read wait or the cooperative pause that
lets the host dispatch interrupts — raises
`OpenAI transport failure (stage=..., category=cancelled)`
(`src/posoco_ext_openai.mbt:164-174,502-513,547-563`). The
`category=cancelled` token is the classification carrier: hosts match on it
instead of provider text, because the raise type cannot carry the coroutine
cancellation itself.

## Wire identity

The extension identifies itself honestly on the wire: `originator` is
`posoco`, never a codex_cli_rs impersonation (the Codex backend accepts
third-party originators; pi and bub do the same). Every request — including
`api.openai.com` calls and model discovery — carries the User-Agent
`posoco/ext-openai ({platform} {release}; {arch})`, assembled from live
platform probes. The full official Codex CLI protocol header shape is
mirrored only when `base_url` is the Codex subscription endpoint:

- `session-id` — the posoco session id from the `InvocationScope`; call sites
  with no session scope fall back to a process-stable UUID
- `thread-id` — a fresh UUID per call, with `x-client-request-id` sharing the
  same value
- `x-codex-window-id` — the session id plus `:0` (window 0)
- `Accept` — `text/event-stream` while streaming, `application/json` otherwise
- `x-codex-installation-id` — a process-stable UUID minted once per process,
  added only on compact requests

Codex model discovery sends `originator` and the User-Agent alongside
`chatgpt-account-id`, not the full protocol set.
