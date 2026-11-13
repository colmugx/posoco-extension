# posoco-ext-pi-adaptor

`posoco-ext-pi-adaptor` is a JavaScript-target compatibility host for loading
Pi ecosystem extensions inside Posoco.

It keeps Posoco's Agent and internal Puppet state machine in control. Pi tool
execution is connected through the public Posoco runtime seam:

```text
Pi package
  -> package.json.pi.extensions
  -> PiPackageHost / PiAdaptor
  -> PiRuntime + ToolContributions
  -> Agent::with_runtime
  -> Posoco Agent
```

The adaptor projects the surfaces a featured Pi package needs for its own
functionality: its tools, its events, its own UI calls, its own slash
commands, its own prompt self-description, and its own persistence.
Host-controlled mechanisms — model routing, providers, tool gating, the user
input pipeline — are not re-wirable by packages (see the projection matrix
below).

## Supported profile

- JavaScript target only
- unmodified Pi extension default exports
- `registerTool` and JSON Schema / TypeBox-compatible parameter objects
  (preserved as JSON Schema; core owns schema validation)
- synchronous and Promise-returning tools
- `AbortSignal` cancellation correlated by Posoco `EffectId`
- lifecycle handlers registered with `pi.on(...)` — the host emits the
  `session_start` / `agent_start` / `turn_start` / `message_*` /
  `tool_execution_*` / `turn_end` / `agent_end` / `agent_settled` family,
  and `onUpdate` callbacks deliver `tool_execution_update` live
- `ctx.ui.select/confirm/input` and `ctx.ui.notify/setStatus/setWidget`
  projected onto the Posoco UI port when the embedding host installs UI
  callbacks (no-op defaults otherwise)
- `registerCommand` / `registerShortcut` handlers, executed through the
  Posoco command port (`pi:<name>` / `pi:#<key>`)
- `promptSnippet` / `promptGuidelines` injected into the model's system
  message on every call
- custom session entries through `appendEntry` (projected as observer
  events and persisted with the session)
- `sendMessage(..., { triggerTurn: true })` and `sendUserMessage` through
  `AgentControl` — parked while idle, delivered on the next host-driven
  turn
- `api.exec` (argv spawn with Pi `ExecResult` semantics; see security caveat below)
- dynamic tool registration through `ToolContributions` revisions
- headless `ExtensionContext` with a session branch; `model` stays `null`
  and the model registry reports no models (model routing is host-owned)

## Supported packages

Per-package verification records. A package lands here only after the
unmodified package is exercised end to end through the cetas-js host.

### [`pi-web-access`](https://github.com/nicobailon/pi-web-access) 0.27.0 — verified

Exercised through the cetas-js host with the bun-installed npm package
(`~/.cetas/pi-packages` umbrella):

| Surface | Status |
| --- | --- |
| Tools | 4/4 registered and model-visible: `web_search`, `source_check`, `fetch_content`, `get_search_content` |
| Tool execution | `fetch_content` executed end to end inside a real agent turn with live network access (smoke-pi.ts, repeated online runs) |
| Commands | `registerCommand` registrations surface as `/pi:websearch`, `/pi:curator`, `/pi:search`, `/pi:google-account` through the `pi:` command namespace (bridge verified against fixtures; the curator's own browser window is not part of the verification) |
| Shortcuts | `registerShortcut` (curator + activity keys) rides the shortcut-only `pi:#<key>` defs |
| Events | `session_start` delivered per session (`new`/`resume` reasons); the package's `session_tree` / `session_shutdown` handlers register but the host never fires those events because it exposes no session-branch or shutdown surface |
| UI | package `ctx.ui.notify/setWidget/select/theme` calls project to the host UI port (theme renders as identity text passthrough) |
| Prompt | the tools' `promptSnippet`s reach the model inside the `<pi-tools>` system-message block |
| Persistence | `appendEntry("web-search-results", ...)` round-trips: observer `Custom` events at emission, `Session.metadata["pi.custom_entries"]` at turn end, restore on the next process via seeded entries; this keeps `get_search_content` usable across restarts |

Not exercised: live provider-backed `web_search` execution (every bundled
search provider needs API keys this lab does not have); `fetch_content` is
the only live-network tool call verified.

## Runtime requirements

- **Bun is required for real npm packages.** Node 22.6+ type-stripping
  refuses TypeScript under `node_modules`
  (`ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`), and real Pi packages ship
  TS sources there. Repo-local `.ts`/`.mjs` fixtures run fine on Node.
- **Module mirror.** Compiled Bun binaries cannot resolve a package's own
  imports, so the cetas-js host rewrites every non-builtin import of the
  entry's dependency closure to absolute file URLs in a temp mirror before
  import (`CETAS_PI_MIRROR=0` bypasses the mirror and imports the original
  file URL — works for plain `bun` runs, not compiled ones).
- **Package allowlist.** `<home>/.cetas/pi-packages.json`:
  `{ "packages": [...], "npmCommand": "npm" }`. `packages` is both the load
  allowlist and the install/remove target list; a missing, empty, or
  malformed file means **zero packages load** (deny by default, no seeding).
  `npmCommand` is the package manager `/pi install|remove` runs (default
  `npm`).
- **SSRF guard vs fake-ip proxies.** pi-web-access's SSRF protection blocks
  the RFC-benchmark ranges that fake-ip TUN proxies use. Point
  `PI_CODING_AGENT_DIR` at a config whose `web-search.json` sets
  `ssrf.allowRanges` for the proxy range, or fetches fail closed.
- **One composition per Bun process.** Bun's dynamic-import runtime inside
  the bundled lib.js negatively caches the first mirrored pi entry it fails
  or finishes loading, so composing a second pi agent in the same process
  reports bogus package-load failures. The smoke family runs one agent per
  process.
- **Idle `sendMessage` delivery.** `sendMessage(..., { triggerTurn: true })`
  while no run is active is parked, not dropped; each parked envelope is
  flushed at the next host-driven turn's first model call and becomes its
  own follow-up turn.
- **`pi.custom_entries` follows lineage.** Entries persist in
  `Session.metadata`, and fork/compact build the child session by copying
  the whole metadata bag, so restored package state carries into derived
  threads.

## Package loading

Build the MoonBit package for the JavaScript target, then create a package
host around the generated ESM module:

```ts
import { PiPackageHost } from "./host.ts";

const host = await PiPackageHost.fromModuleUrl(
  new URL(
    "./_build/js/debug/build/colmugx/posoco-ext-pi-adaptor/posoco-ext-pi-adaptor.js",
    import.meta.url,
  ),
  {
    cwd: process.cwd(),
    projectTrusted: false,
  },
);

const loaded = await host.loadPackage("pi-web-access");
await host.startSession();
console.log(loaded.extensions);
console.log(host.catalog());
```

`loadPackage` resolves the package root, reads
`package.json.pi.extensions` and loads every declared extension entry. Load all
required Pi packages, seed any restored custom entries, then call
`startSession()` once for the Posoco session.

Pi extensions execute arbitrary JavaScript. Only load packages allowed by the
embedding application's extension policy.

## Posoco composition

`PiAdaptor` is a normal Posoco `Extension` and `ToolProvider`. Its manifest
contributes one port per projected Pi surface:

| Port | Contribution |
| --- | --- |
| `ToolProvider` (`PiAdaptor` itself) | registered Pi tools as `ToolDef`s, minus host-shadowed names |
| `Observer` (`PiEventObserver`) | projects turn events onto the package's `pi.on(...)` handlers |
| `PipelineHook` (`PiHook`) | injects the `<pi-tools>` prompt block at `before_model` |
| `CommandPort` (`PiCommandPort`) | `pi:<name>` commands and `pi:#<key>` shortcut defs |

Full async Pi execution uses `PiRuntime` with Posoco's standard
`Agent::with_runtime` seam. Dynamic tools use the same Agent's owner-bound
`ToolContributions` capability; the former `CatalogSource` API is retired.

```moonbit
let pi = @pi.PiAdaptor()
// Load allowed Pi extensions before composition.
let fallback = @runtime.PortRuntime(model~)
let pi_runtime = @pi.PiRuntime(
  adaptor=pi,
  fallback=fallback as &@runtime.Runtime,
)
let agent = @posoco.Agent::with_runtime(
  exts=extensions_with_pi,
  config=agent_config,
  events=event_system,
  runtime=pi_runtime as &@runtime.Runtime,
)
pi_runtime.attach_control(agent.control())
```

The manifest contributes ToolProvider, Observer, Hook and CommandPort **plus
Lifecycle** for obtaining the dynamic contribution handle. Tools already
present at composition are static. Only tools registered afterward may enter
the dynamic group: Posoco rejects duplicate names even within one owner.
Accepted dynamic revisions apply to future admitted operations, not a
currently captured tool directory.

## Source ownership

| Layer | Files | Responsibility |
| --- | --- | --- |
| Composition | `src/adaptor.mbt` | One Pi guest, extension manifest and capability bindings |
| Guest | `src/pi_guest_*.mbt` | JS-only Pi API emulation, loading, catalog FFI, effects and events |
| Tool ports | `src/tool_catalog.mbt`, `src/tool_execution.mbt` | Tool definitions, static/dynamic distinction and sync port calls |
| Runtime | `src/runtime_adaptor.mbt` | Posoco effects, cancellation, follow-up messages and fallback |
| Projections | `src/hook_adaptor.mbt`, `src/event_observer.mbt`, `src/command_adaptor.mbt` | Prompt, event and command mapping |
| Guest exports | `src/guest_observability.mbt` | UI, session, command and event host API |

A future Native JavaScript engine will be a separate guest backend, not
another implementation of Pi/Posoco semantics.

## Tool schemas

Posoco 0.24.2 uses `colmugx/json-schema@0.1.5` to validate JSON Schema
2020-12. The former projector dropped union and constraint keywords due to an
old core limitation; that silently weakened schemas. ToolDef and guest catalog
now preserve the original Pi/TypeBox JSON Schema without lossy projection.
Unsupported or invalid schemas should fail at Posoco's catalog validation
boundary instead of being made permissive.

## Promise bridging

Promise-returning Pi tools are bridged into moonbitlang/async
(`src/promise_bridge.mbt`): the foreign JS Promise is cast to an
`@js_async.Promise` and awaited through `Promise::wait`, which performs the
wake + reschedule that the JS target's missing background scheduler pump
would otherwise omit (a raw `%async.suspend` resumed straight from the
settling JS microtask deadlocks callers parked in spawned sub-coroutines,
such as the agent turn's `@async.all` wave executor). Constraint: waiters
must run inside a `from_async`-scheduled coroutine — on a bare `%async.run`
root `Promise::wait` panics because no coroutine is current.

## Prompt projection

Tool-level `promptSnippet` / `promptGuidelines` are projected: a `PipelineHook`
(`src/hook_adaptor.mbt`) appends one delimited `<pi-tools>` block to the system
message at Posoco's per-turn `before_model` boundary, built from live host state and shaped like pi's
own rendering (`Available tools:` lines in registration order, deduplicated
`Guidelines:` bullets). It rides `before_model` because the
`SystemPromptContributor` contract is stable-only and forbids dynamic
catalogs; hidden tools (base wins, see the projection matrix) contribute
nothing to the block.

Not projected into the model request: `pi.on("before_agent_start", ...)`
returning `{ systemPrompt }`, `resources_discover` contributions such as
skills and prompt files, and `context` event message rewriting. Handlers may
register and stay visible through the event registry, but the host does not
emit a `before_agent_start` hook point before model calls. A package may load
and register tools successfully while still losing such instructions — that
gap is why the ecosystem scan below marks several packages incompatible even
though they load.

## Projection matrix and known limitations

| Pi API | Posoco mapping | Behavior |
| --- | --- | --- |
| `registerTool` and parameters | `ToolProvider` + `ToolContributions` | Full schemas; late additions published for future operations |
| `setActiveTools` / `getActiveTools` | Guest active view + `PipelineHook::tool_exposure` | Narrows active tools at the next operation boundary; existing operations retain their captured catalog |
| `on(...)` and `onUpdate` | `Observer`, guest event callbacks | Representative lifecycle/tool events; updates are guest-side |
| `ctx.ui.*` | Installed host callbacks | Interactive if host provides UI; headless fallback otherwise |
| `registerCommand`, `registerShortcut` | `CommandPort` | `pi:` namespace |
| `promptSnippet`, `promptGuidelines` | `PipelineHook::before_model` | Per-turn persistent transcript rewrite, not per-model-call injection |
| `sendMessage(triggerTurn)` | `AgentControl::enqueue_follow_up` | Parked while idle, retried on subsequent turn |
| `appendEntry` | Host Session metadata | Seeding and persistence remain host-owned |
| `api.exec` | JS `node:child_process` | Outside Posoco permission governance; explicit trust risk |

Not fully implemented: `before_agent_start`, `context` mutation,
`pi.events`, model/provider mutation, session-branch events, arbitrary
custom TUI renderers and child-Pi runtimes.

The adaptor is best-effort and must **not** modify Posoco's kernel or weaken
Posoco's tool permission and validation contract just to increase compatibility.

`before_model` runs once at the turn's pump entry, NOT once per model step,
and its changes are persisted. Pi packages depending on ephemeral model-step
request rewriting are not currently compatible.

## AgentHarness (pi "v3") mapping

The adaptor targets the shipped v1 `ExtensionAPI` on purpose: released
pi-coding-agent versions still speak v1 verbatim, the harness scaffolding
throws `HarnessNotImplemented` for nearly everything, and no ecosystem
package imports harness APIs yet. When that changes, the port lookup is:

| AgentHarness concept | Posoco port | Current v1 projection |
| --- | --- | --- |
| passive event stream (`watch` / `events.on` — listeners cannot mutate) | `Observer` | `PiEventObserver` projects turn events into `pi.on(...)` handlers |
| `before_run` / `transform_context` (messages append / systemPrompt replace) | `PipelineHook::before_model` | `PiHook` `<pi-tools>` block; context rewriting parked |
| `before_tool` (chained argument replacement, revalidated; block fails closed) | `PipelineHook::before_tool` | default `Approve` — argument rewriting is disabled because core validates reducer-side before hooks and does not revalidate after a rewrite; rewriting requires paired revalidation |
| `before_run_end` follow-up | `AgentControl::enqueue_follow_up` | `PiRuntime` parked-followup queue flushed at the next `call_model` |

Pi version knowledge lives entirely in the adaptor's JS bridge. Its by-name
dispatch tolerates absent members, so an AgentHarness migration can be handled
inside `pi_bridge.mbt` and manifest filling without changing the Posoco ports
above.

## Trust model

The headless Pi context reports an untrusted project by default:

```ts
projectTrusted: false
```

The embedding host may opt in only after applying its own workspace trust
policy:

```ts
const host = await PiPackageHost.fromModuleUrl(moduleUrl, {
  cwd,
  projectTrusted: true,
});
```

## Ecosystem compatibility scan

Beyond the supported package above, the currently active Pi package ecosystem
was source-reviewed against the adaptor's exposed API surface. Statuses are
re-checked against the current projection matrix; the ❌ rows stand on their
remaining unprojected dependencies.

- ❌ **Not currently compatible** — the package's primary documented behavior
  depends on Pi APIs that the adaptor does not project.

| Package | Status | Assessment |
| --- | :---: | --- |
| [`gentle-engram`](https://pi.dev/packages/gentle-engram) | ❌ | Its `mem_*` tools may register and execute, but the package's memory protocol depends on chained `before_agent_start` system-prompt injection and `session_compact` recovery, neither of which is projected. (`tool_execution_end` passive capture, its other dependency, is now bridged.) |
| [`pi-mcp-adapter`](https://pi.dev/packages/pi-mcp-adapter) | ❌ | Core initialization and dynamic operation use `pi.events`, flags, `getAllTools`, active-tool mutation and tool removal. Commands and interactive UI no longer block (both are projected now), but these host-control surfaces remain. |
| [`pi-subagents`](https://pi.dev/packages/pi-subagents) | ❌ | Its core is a child-Pi runtime with spawned processes, model/session control, background jobs, intercom and TUI state. A registered-tool bridge cannot reproduce those semantics. |
| [`pi-fabric`](https://pi.dev/packages/pi-fabric) | ❌ | Depends on registered-tool interception, `pi.events`, active-tool ownership, context/message/tool middleware, compaction, child agents/actors and TUI controllers. |
| [`pi-mcp-extension`](https://pi.dev/packages/pi-mcp-extension) | ❌ | Dynamic server refresh relies on `getActiveTools` / `setActiveTools` — host tool gating is a deliberate non-goal. Its commands would execute under the `pi:` namespace, but that does not carry the package's core. |
| [`pi-soly`](https://pi.dev/packages/pi-soly) | ❌ | Its core workflow depends on `before_agent_start` prompt replacement, resource context, active-tool inspection, input/turn/tool hooks and session branch APIs. |
| [`@vigolium/piolium`](https://pi.dev/packages/%40vigolium%2Fpiolium) | ❌ | Built around sub-agent execution, provider/model access, flags, prompts and themes — provider composition and theme ownership stay with the host. |

## Port-only mode

Using `PiAdaptor` only as a normal `ToolProvider` supports tools that return a
result synchronously. Promise execution, effect-correlated cancellation,
dynamic catalogs and background follow-up turns require `PiRuntime` through
`Agent::with_runtime`.

## Current boundaries

- `before_agent_start` replacement, `context` rewriting, `resources_discover`,
  `session_compact` and session-branch events (`session_tree`,
  `session_shutdown`) have no host-side projection: handlers register but the
  corresponding hook points or events never fire.
- `onUpdate` partial results reach the package's own
  `tool_execution_update` handlers live; they are not mirrored into the
  Posoco observer stream.
- message/tool renderers are captured but rendering stays host-owned.
- host-control surfaces (`setActiveTools`, `setModel`, `registerProvider`,
  `input`, `user_bash`, provider interception) are deliberate non-goals —
  Posoco owns the model routing, tool gating and input pipeline.
- without installed UI callbacks the context degrades to no-op defaults
  (`confirm` = false, `select`/`input` = undefined, renders dropped).
- `model` is `null` and the headless model registry reports no available
  models.
- follow-up conversion currently projects textual Pi messages to Posoco user
  messages; the original envelope remains available for diagnostics.

## Development

```bash
moon check --target js --deny-warn
moon test --target js
moon build --target js
npm run test:node
```

The Node fixture suite (`test/host.test.mjs`, 16 tests) covers multi-entry
package loading, trust propagation, the UI callback bridge, Promise
execution, `EffectId` cancellation, follow-up capture, custom-entry
drain/restore, schema projection, base-wins tool hiding, the `pi:` command
namespace and `api.exec`. The real-package probe
`test/pi-web-access.test.mjs` (4 tests) loads `pi-web-access` from
`~/.cetas/pi-packages` and must run under Bun (it skips when the package is
absent or when Node cannot type-strip it).
