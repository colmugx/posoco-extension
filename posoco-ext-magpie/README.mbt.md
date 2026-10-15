# posoco-ext-magpie

Independent Gateway-aware Model Manager for Posoco, not a provider hosted by
`posoco-ext-llm`.

## Live gateway compatibility (PR #113)

`src/harness/` is an opt-in executable that validates this extension
against a real Magpie gateway. It is never part of CI: without
configuration it prints `RESULT: SKIPPED` and touches nothing.

```bash
# read-only smoke (10 gateway GETs, zero billable requests)
MAGPIE_LIVE_URL=http://127.0.0.1:3425 moon run --target native posoco-ext-magpie/src/harness

# with billable inference and cache-economics verification (≤14 small requests)
MAGPIE_LIVE_URL=... MAGPIE_LIVE_KEY=... MAGPIE_LIVE_INFER=1 moon run --target native posoco-ext-magpie/src/harness
```

`MAGPIE_LIVE_KEY` is optional; local gateways accept any key and use it to
name the caller in usage pages. Reports stream line by line and record
sanitized schema shapes only — field names, types, counts, model ids,
usage numbers; never keys, raw bodies, or account details.

### Compatibility matrix

Observation sources are explicit: **LIVE** = executed against a real
gateway (magpie 0.1.1224, localhost, read-only pass on 2026-10-15),
**SIM** = deterministic fake-transport tests in the offline suite,
**N/E** = not exercised live (see limitations).

| Area | Source | Observation |
|---|---|---|
| `/api/hello` identity | LIVE | `{name, version}`; version text drives the Connected status line |
| `/v1/models` catalog | LIVE | 72 entries; `data/first_id/has_more/last_id/object`; native endpoints for all three protocols declared; routing groups present |
| `/v1/magpie/route` | LIVE | `{route, seq, session}`; empty session → `route: null` |
| `/v1/magpie/quotas` | LIVE | 6 provider cards; two error cards (signed-out / disabled providers) surface as per-card errors while others render |
| `/v1/magpie/limit` | LIVE | `{key, limited}` |
| `/v1/magpie/usage` | LIVE | superset schema (`series`, `by`, `through/direct/reported`); our decoder reads only the modeled fields — compatible |
| `/v1/magpie/usage/requests` | LIVE | `{rows, offset, total, by, through, direct, reported}`; superset tolerated |
| `/v1/magpie/concurrency` | LIVE | `{data: {}, object}` |
| Auth classification | LIVE (note) | local gateways accept any key and name the caller; restricted-key 401/403 paths remain SIM (fake transport) |
| Runtime commands ×10 | LIVE | all PASS incl. structured + human output; `magpie_model` lists the real catalog; quota errors do not touch inference |
| Messages native execution | SIM | full request/parse/stream/tool/replay coverage |
| Responses native execution | SIM | idem |
| Chat Completions native execution | SIM | idem |
| Streaming SSE parsing | SIM | event/data scripts, thinking replay, usage tail, incomplete EOF → explicit parse error |
| Tool-call round trips | SIM | tool_use emission and result replay |
| Reasoning effort wiring | SIM | advertised efforts selected, unknown rejected |
| Cache economics (creation/read) | N/E | harness ready (stable prefix, `cache_control` ephemeral only, upstream-usage verdicts); not yet run live |
| Cancellation / reconnect / shutdown | SIM | next-line cancellation points, offline→reconnect, deactivation semantics |
| Rate limiting (429) | SIM | classified, isolated to the execution |

### Remaining production-readiness limitations

- Billable inference was attempted once against the live gateway and was
  cut short by the 5s default transport timeout (an inference-sized
  request needs more); the harness now builds its transport with a
  120s timeout. Re-running requires `MAGPIE_LIVE_INFER=1` and should
  stay below the gateway's per-key rate limits — stop at the first
  sign of `limited` rather than pushing through.
- Restricted-key 401/403 classification and cache-hit proof are still
  pending a live run; until then they are proven only in simulation.
- The `magpie_model` command id intentionally differs from ext-llm's
  resident `model` command so both extensions can coexist in one Agent.
- Report streaming, a Result-shaped POST path, and the 120s timeout were
  added to the harness after the aborted live inference attempt; the
  read-only smoke was re-verified green afterwards (19 passed / 3
  skipped / 0 billable).

## Runtime integration

`MagpieRuntime::activate(settings?, transport?)` is the one-call activation
path: typed settings in (`base_url`, `gateway_key`, `enabled`, `model`,
`effort`), manager + model port + intelligence wired, invalid settings
recovered to a disabled local configuration with a recorded reason. Activation never performs
I/O — `on_start` refreshes the catalog and an offline gateway leaves the
explicit offline state instead of failing startup; `on_shutdown`
deactivates the runtime and drops owned observation state.

The runtime implements `@posoco.Extension` (manifest
`posoco_ext_magpie`: one ModelPort, the commands, the lifecycle),
`@posoco.CommandPort`, and `@posoco.Lifecycle` following the repository's
existing extension conventions — the same shape `posoco-ext-llm` and
`posoco-ext-zai` use. The manager owns selection state; the runtime adds no
competing registry. Magpie remains a peer-level Model Manager; no production dependency on ext-llm or its provider types is required.

Commands (category `magpie`, following the existing `model` command
conventions):

| Command | Effect |
|---|---|
| `magpie_model` [model] [effort] | no args: structured catalog; with args: select model / apply effort (unknown/unadvertised → argument error) |
| `magpie_status` | gateway connection, selection + pending, catalog size, per-service availability, unconfigured reason |
| `magpie_refresh` | re-read `/v1/models`; offline gateway → explicit failure outcome, not a crash |
| `magpie_route` (session) | routing decision for a session; failures surface without session identifiers |
| `magpie_quotas` [kept] | quota cards; 403 `gateway_key_held` → failure outcome while inference continues |
| `magpie_limit` | the calling key's own limit |
| `magpie_usage` [period] | usage summary with the gateway's own cost |
| `magpie_requests` [period] [offset] [limit] | request history, one page at a time |
| `magpie_concurrency` | in-flight / waiting / tool-wait counts |
| `magpie_usage_recent` | this runtime's recent execution reports (canonical usage, cache numbers, served model, protocol, translated flag) |

Session affinity keeps using the Posoco session id through the port; the
route command takes an explicit session argument because the command
framework carries no implicit session. Intelligence service errors fail
their own command and never touch the model port.

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

This is a complete runtime extension, but not a quota administration layer:
no dashboards, no automatic account switching, no duplicated gateway routing
or pricing logic. Configuration accepts the gateway key as a plain setting
value (hosts reading it from a credential store pass the value through; the
extension persists nothing to disk). Magpie has no dependency on
`posoco-ext-llm` or `posoco-kit-provider`; coexistence is verified against
the core composition contract itself (see the host-level acceptance tests).

## Operational guide

### Installation and activation

Magpie is a MoonBit module, so a Host installs it by adding the dependency
and composing it at agent construction — Posoco has no runtime plugin
discovery, and the `Extension` manifest is the discovery surface:

```mbt nocheck
let runtime = @magpie.MagpieRuntime::activate(
  settings=Some(settings_json),
  transport=@magpie.magpie_http_transport(timeout_ms=120000),
)
let agent = @posoco.Agent::Agent(exts=[runtime], config=my_agent_config)
```

One `activate` call wires the Model Manager, the ModelPort and the
intelligence client; `Agent::Agent` then registers the model slot, the ten
`magpie_*` commands and the lifecycle from the manifest. The host-level
acceptance tests (`host_integration_wbtest.mbt`) are the installation and
activation proof: they compose a real `Agent::Agent` and drive every check
through the composed agent's own command surface.

### Configuration

Settings arrive as one JSON object; wrong-typed values degrade to the
documented defaults with a recorded `unconfigured_reason` — an invalid
configuration never silently activates the default gateway:

```json
{
  "base_url": "http://127.0.0.1:3425",
  "gateway_key": "sk-...",
  "enabled": true,
  "model": "anthropic/claude-native",
  "effort": "high"
}
```

- `base_url` — gateway address. Loopback endpoints work without a key; a
  remote `base_url` without `gateway_key` refuses to refresh
  (`NotConfigured`), the key never leaves the machine implicitly.
- `gateway_key` — the extension persists nothing to disk; a Host that keeps
  secrets in a credential store reads the value and passes it in here.
- `enabled` — `false` (or a broken setting that falls back to `false`)
  makes every catalog refresh raise `Disabled`: the extension stays
  installed but inert.
- `model`, `effort` — optional selection seeds; they apply as pending
  selections until confirmed against a loaded catalog.

### First run

The complete path, each step covered by the host-level tests in this order:
install and compose (activation proof) → `magpie_status` verifies the
connection (`connected: true`) → `magpie_model` with no argument lists
models and routing groups (opaque ids, verbatim) → `magpie_model` with
`{"model": "<id>", "effort": "<level>"}` selects → send the first message
through the composed Agent (the lifecycle refreshes the catalog on the
first turn automatically) → `magpie_route` shows the session's routing
decision, `magpie_usage` / `magpie_quotas` / `magpie_limit` show account
state. An unavailable gateway cannot crash Host startup: `on_start`
swallows the refresh error and `magpie_status` reports the disconnected
state until a later refresh succeeds.

### Commands

All ten commands are namespaced `magpie_*`, so no global command
collisions are possible (the core composition raises `CommandCollision`
on any duplicate id, and the host-level suite asserts all ten survive
composition). `magpie_model`, `magpie_status` and `magpie_usage_recent`
work fully offline against cached state; the account-backed commands
(`magpie_route`, `magpie_quotas`, `magpie_limit`, `magpie_usage`,
`magpie_requests`, `magpie_concurrency`) degrade to explicit
`Failure`/offline answers when the gateway forbids those services — the
command surface itself never requires a specific Intelligence service.

### Native versus translated protocol selection

Models advertising a native endpoint in `native_endpoints` are addressed
on that protocol verbatim (`/v1/messages`, `/v1/responses`,
`/v1/chat/completions`); models without one are executed through the
translated path, which requires the explicit opt-in and rejects any
fidelity-risky transformation. Routing groups (`"group": true`) are
selected like models; the gateway does the internal scheduling and the
`X-Magpie-Session` header (derived from the Posoco session id) keeps
affinity. Magpie never reproduces the gateway's routing algorithm.

### Cache economics

5-minute cache writes are exercised by the live harness behind
`MAGPIE_LIVE_INFER=1`; one-hour writes additionally require
`MAGPIE_LIVE_CACHE_1H=1` and are never enabled by default. Cache numbers
are reported only from gateway usage fields; a cold turn whose usage
lacks cache fields is reported unsupported, not failed. See the
production-readiness section above for the recorded evidence and the
explicit list of what remains live-unverified.

### Two model managers, coexistence

Posoco's composition allows exactly one ModelPort per Agent
(`MultipleModels` otherwise) and unique command ids across extensions.
Two Model Managers therefore coexist as: one per Agent (separate agents,
independent selection state — asserted by the host-level tests), never
two in one Agent. Magpie holds no global registry, so two runtime
instances never share selection state.

### Lifecycle

`activate` → `on_start` (catalog refresh; offline tolerated) → turns →
`on_shutdown` (deactivates the runtime, clears the in-memory report log,
commands refuse with an explicit error). A following `on_start` cycle
reactivates: this repair is covered by the repeated-lifecycle host test.
Repeated `activate` calls simply build independent runtimes.

### Troubleshooting

| Symptom | Meaning | Action |
|---|---|---|
| `magpie_status`: `connected: false` | gateway unreachable or refresh failed | check `base_url`; fix and re-run `magpie_refresh` or restart the turn |
| `unconfigured_reason` set | settings failed to parse; defaults with `enabled: false` took over | correct the settings and recompose |
| refresh says `Disabled` | `enabled: false` in effect | enable explicitly; nothing activates by default |
| refresh says `NotConfigured` | remote gateway without `gateway_key` | configure a key from your credential store |
| selection reports `pending` | seeded `model`/`effort` not yet confirmed against a catalog | refresh, then select a catalog id |
| commands answer `deactivated` | runtime after `on_shutdown` | start a new lifecycle cycle (`on_start`) |

### Known compatibility limitations

Unchanged from the production-readiness section: real streaming events,
one-hour cache writes, restricted-key 401/403 and disconnect-on-shared-
gateway remain verified only by the opt-in live harness, not by CI. The
catalog parser keeps unknown fields verbatim; a gateway dropping
`native_endpoints` degrades those models to translated execution. No
 Posoco Core, Cetas, ZAI, ZAI Coding Plan or ZCode code is modified, and
the three protocol kits are untouched.

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
