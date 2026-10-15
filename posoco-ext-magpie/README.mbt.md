# posoco-ext-magpie

Independent Gateway-aware Model Manager for Posoco, not a provider hosted by
`posoco-ext-llm`.

## Implemented in this PR

- Multi-protocol ModelPort execution (`MagpieModelPort`): consumes the
  validated `MagpieProtocolPlan`, re-planned fresh from the current catalog
  on every call, so a plan is always checked against the catalog it runs
  against. One call is one plan, one endpoint, one attempt — no silent
  fallback between models or protocols, no automatic retries of requests
  that may already have produced output.
- Three execution adapters over the existing protocol kits
  (`posoco-kit-messages`, `posoco-kit-responses`,
  `posoco/kit-chat-completions`): request encoding, response parsing and
  SSE event decoding are the kits' own; the adapters own request assembly,
  endpoint selection, status classification, and error mapping.
- Streaming and tools: incremental SSE decoding, text and reasoning deltas,
  tool calls with argument assembly (parallel calls included), tool
  results, image inputs (downgraded to explicit placeholders for models
  without declared image input — never a silent drop), stream cancellation,
  provider errors, incomplete-stream detection, and final usage.
- Native Messages fidelity: thinking blocks and signatures travel in the
  kit's replay envelope (captured on decode, re-expanded on encode);
  tool-use identities are preserved; cache marking is policy-driven and
  defaults to untouched; native cache creation/read numbers are preserved
  separately from the canonical usage. A native endpoint declaration alone
  never claims extended thinking or cache support — planning separates
  protocol support, model capability, and unknown upstream behavior, and
  reports cache hits only from usage evidence.
- Session affinity: `X-Magpie-Session` carries the Posoco session id,
  stable across turns, distinct across sessions, one identity per call
  (never per tool call), omitted when no identity exists, and never logged
  or reported.
- Usage and observability: `MagpieExecutionReport` captures the requested
  model ID, the gateway-served model, protocol, native vs translated
  endpoint, canonical usage, native cache read/write tokens, protocol
  finish reason, and the gateway response id — delivered to a caller
  supplied sink, designed for later routing/quota/cost attachments. Cost
  data is never fabricated.
- Gateway intelligence (`MagpieGatewayIntelligence`): a typed, read-only
  client for the documented control and observability endpoints —
  `GET /v1/magpie/route?session=…` (with `after`/`wait` long-poll),
  `GET /v1/magpie/quotas` (`?kept=1` for the cached answer),
  `POST /v1/magpie/quotas/refresh`, `GET /v1/magpie/limit`,
  `GET /v1/magpie/usage?period=…`, `GET /v1/magpie/usage/requests`
  (`offset`/`limit` ≤ 500), and `GET /v1/magpie/concurrency`. Typed
  snapshots (`MagpieRouteSnapshot`, `MagpieQuotaSnapshot`,
  `MagpieKeyLimit`, `MagpieUsageSummary`, `MagpieUsageRequestsPage`,
  `MagpieConcurrencySnapshot`) follow the gateway's observed field shapes —
  asked/group/rule/model/effort/served/tries with fallback reasons on the
  route, windows with used/remaining/resets per card, session rows,
  request-history rows with served/model attribution, cost, and cache
  numbers. Query values are percent-encoded; the usage rows' cache numbers
  can be run through the messages kit's cache economics with a caller
  supplied rate card.

- Typed gateway URL, local/remote authentication and redacted configuration.
- `GET /api/hello` identity verification and `GET /v1/models` catalog refresh.
- Injectable transport and deterministic fake gateway tests.
- Atomic refresh, last-known-good catalog and explicit offline/error status.
- Provider-neutral `ModelManagerControl` selection, opaque IDs and effort levels.
- Raw catalog entries retained alongside manager-neutral model projections.
- Typed `MagpieModelMetadata`: `magpie_label`, `context_window`,
  `context_length`, `max_input_tokens`, `max_output_tokens`, declared input
  modalities, the `reasoning` declaration, `supported_reasoning_levels`
  (exact strings, server order), typed `native_endpoints` (unknown paths
  retained without a protocol), and routing-group identity via the `group/`
  id namespace. Optional fields distinguish unknown (`None`) from explicitly
  declared, including declared-empty; unknown extension metadata stays on
  the raw entry. Model IDs are never split or assumed to carry one slash.
- Typed protocol planning (`plan_protocol`, `evaluate_protocol`): Anthropic
  Messages, OpenAI Responses and OpenAI Chat Completions evaluated
  independently, composed under a caller preference and an explicit
  `MagpieTranslationPolicy` into either a structured plan or an explicit
  incompatibility with per-protocol blockers. Pure and deterministic.

### Execution architecture

`MagpieModelPort(manager~, transport?, policy?, preference?, require_*?,
report_sink?)` implements Posoco's `ModelPort` (`chat`, `compact`,
`provider_config`). Each `chat` call:

1. reads the active selection and rejects pending/absent selections before
   any request;
2. re-plans from the current catalog under the port's strictness dials
   (`require_signed_thinking_replay`, `require_native_prompt_caching`,
   `require_reasoning_output`) and the translation policy — a planning
   rejection raises `RequestBuild` with the per-protocol blockers;
3. dispatches to the protocol adapter at the planned endpoint (the declared
   native path, or the protocol's canonical path when translated);
4. decodes through the protocol kit and returns the completion with the
   input transcript as `processed_messages`;
5. emits `MagpieExecutionReport` to the sink.

`compact` rides the selected protocol as a plain non-streaming
summarization call (keep the recent tail verbatim, summarize the head,
replace in place). `provider_config` reports the active model's advertised
effort ladder and declared context window — unknown windows stay unknown.

Errors map onto Posoco's `ModelError`: planning/selection failures to
`RequestBuild`, network/HTTP failures to `Transport` (statuses 401, 403 and
5xx carry stage/status/body-size only — bodies are counted, never quoted;
429 goes through the rate-limit kit and keeps the structured verdict), and
malformed payloads to `ResponseParse`.

Use `MagpieConfig::MagpieConfig(...)` and
`MagpieManager::MagpieManager(config=...)`, then call
`manager.refresh()` before offering models to users, and execute through
`MagpieModelPort::MagpieModelPort(manager~, ...)`. `manager.catalog_entry(id)`
hands out an isolated typed entry for `plan_protocol`:

```mbt nocheck
let outcome = plan_protocol(
  entry,
  requirements=MagpieRequirements::MagpieRequirements(
    tools=true,
    streaming=true,
    signed_thinking_replay=true,
  ),
  preference=Prefer(Responses),
  policy=NativeOnly,
)
```

A `Planned` outcome carries the selected endpoint path, native vs
gateway-translated kind, confidence, a fixed-order capability matrix with
evidence source and status per requested feature, fidelity risks, explicit
unsupported requirements, and the selection reasons. Evidence tiers are
never mixed: `ProtocolNative`, `CatalogDeclared`, `GatewayLevel`, and
`Unknown`. Missing `native_endpoints` is unknown, never a prohibition.
Signed thinking and native prompt caching are protocol-native only through a
declared native Anthropic Messages endpoint, and routing groups never
inherit one — their upstream members may change per request. Declared-fact
rejections (images on a text-only model, an effort outside the advertised
ladder) block every policy; required-but-unguaranteed features are planned
only under `AllowTranslated`, with the risks kept on the plan.

### Permission behavior and service availability

`MagpieGatewayIntelligence::service_availability(service)` reports, per
service and independent from inference: `Accessible`, `Forbidden` (401
unauthenticated / 403 forbidden — the documented `gateway_key_held` denial
code is recognized and quoted; bodies never are), `TemporarilyUnavailable`
(429/5xx/unreachable), `NotSupported` (404 — gateway version without the
endpoint), or `Unknown` (never probed). A 403 on quotas or concurrency
never marks the manager offline: inference keeps working, the manager's own
connection status is untouched, and the next refresh or chat call proceeds
normally. Session identifiers never appear in intelligence diagnostics;
error messages quote stages, statuses, and documented codes only.

### Capability matrix

`CatalogDeclared` rows depend on the model's catalog entry; everything the
gateway does by translation is `GatewayLevel` at best and never assumed to
preserve cache-control or thinking-signature semantics.

| Feature | Native Messages | Native Responses | Native Chat | Translated |
|---|---|---|---|---|
| Tool calls | ProtocolNative | ProtocolNative | ProtocolNative | GatewayLevel |
| Streaming | ProtocolNative | ProtocolNative | ProtocolNative | GatewayLevel |
| Images | CatalogDeclared | CatalogDeclared | CatalogDeclared | CatalogDeclared / Unknown |
| Reasoning output | CatalogDeclared | CatalogDeclared | CatalogDeclared | CatalogDeclared / Unknown |
| Signed thinking replay | ProtocolNative | Unknown | Unknown | GatewayLevel / Unknown |
| Reasoning effort | CatalogDeclared | CatalogDeclared | CatalogDeclared | CatalogDeclared / Unknown |
| Native prompt caching | ProtocolNative | Unknown | Unknown | Unknown |
| Token usage integrity | ProtocolNative | ProtocolNative | ProtocolNative | GatewayLevel |
| Cancellation | ProtocolNative | ProtocolNative | ProtocolNative | GatewayLevel |

## Deliberately not implemented yet

Execution is in, but this is still not a quota or administration layer: no
quota dashboards, no global usage dashboards, no administrative APIs, and no
duplicated gateway routing logic. Do not present a successful catalog
refresh or a completed execution as proof of future availability — every
call re-validates. Later PRs can attach gateway routing, quota and cost
observations to the execution report sink; actual cache-hit and cost claims
require upstream usage evidence and are never fabricated here.

Remaining follow-ups: `count_tokens` integration, reported-usage POSTing
(`POST /v1/magpie/usage/requests`), and quota telemetry.

## Catalog limitations

The parser preserves each raw Magpie JSON entry verbatim, including
`magpie_label`, `native_endpoints`, `context_length`, `max_input_tokens`,
`max_output_tokens` and future extension fields; the typed
`MagpieModelMetadata` projection sits next to the conservative
`ManagerModelInfo` subset. Missing `native_endpoints` does not mean that the
gateway cannot translate requests to a given model — planning reports it as
`Unknown` and lets the translation policy decide.

Deterministic tests exercise synthetic representative catalog rows for every
planning case, plus the complete real `/v1/models` response captured from
the local gateway as a frozen structural fixture: its assertions derive from
the fixture itself (decode, order, verbatim efforts, group identity, typed
endpoints, raw retention) and hardcode no catalog size or contents, so they
hold for any gateway configuration, a single-model gateway included. No test
touches a running gateway.

The execution suite adds a fake gateway with scripted POST and SSE steps,
covering: native Messages / Responses / Chat Completions execution;
routing-group execution; translated execution with the explicit opt-in and
strict fidelity rejection; streaming text; signed-thinking replay; tool
round trips and parallel tool calls; usage and cache accounting; session
affinity (stable, isolated, omitted when unavailable); mid-stream
cancellation; incomplete streams; 401/429/503 handling; and catalog refresh
invalidating a plan. Runs on native, JS and Wasm.

## Testing

From the workspace root, run `moon check --target native`,
`moon check --target js`, `moon check --target wasm`,
`moon test --target native -p colmugx/posoco-ext-magpie`, and `moon info`.
