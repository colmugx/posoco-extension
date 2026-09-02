# posoco-ext-pi-adaptor

`posoco-ext-pi-adaptor` is a JavaScript-target compatibility host for loading
Pi ecosystem extensions inside Posoco 0.14.

It keeps Posoco's Agent and internal Puppet state machine in control. Pi tool
execution is connected through the public Posoco runtime seam:

```text
Pi package
  -> package.json.pi.extensions
  -> PiPackageHost / PiAdaptor
  -> PiRuntime + PiCatalogSource
  -> Agent::with_runtime
  -> Posoco Agent
```

## Supported profile

- JavaScript target only
- Node.js 22.6 or later suffices for repo-local `.ts`/`.mjs` extension code
  (Node type-stripping); real npm-installed Pi packages keep their TypeScript
  under `node_modules`, which Node refuses to type-strip
  (`ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`) — loading those requires
  Bun or a jiti-style loader
- unmodified Pi extension default exports
- `registerTool` and JSON Schema / TypeBox-compatible parameter objects
- synchronous and Promise-returning tools
- `AbortSignal` cancellation correlated by Posoco `EffectId`
- lifecycle handlers registered with `pi.on(...)`
- custom session entries through `appendEntry`
- `sendMessage(..., { triggerTurn: true })` through `RuntimeControl`
- dynamic tool registration through `CatalogSource` revisions
- shortcut, command, message-renderer and tool-renderer registration capture
- headless `ExtensionContext` with a session branch and no-op semantic UI

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

`PiAdaptor` is a normal Posoco `Extension` and `ToolProvider`. Complete Pi tool
semantics use `PiRuntime` and `PiCatalogSource` with `Agent::with_runtime`:

```moonbit
let pi = @pi.PiAdaptor()
let port_runtime = @runtime.PortRuntime(
  model~,
  tools=ordinary_tool_routes,
)
let pi_runtime = @pi.PiRuntime(
  adaptor=pi,
  fallback=port_runtime as &@runtime.Runtime,
)
let catalog = @pi.PiCatalogSource(
  adaptor=pi,
  base_tools=ordinary_tool_defs,
)
let agent = @posoco.Agent::with_runtime(
  exts=extensions,
  config=agent_config,
  runtime=pi_runtime as &@runtime.Runtime,
  catalog_source=catalog as &@runtime.CatalogSource,
)

pi_runtime.attach_control(agent.control())
```

`PiRuntime` delegates model calls, compaction and non-Pi tools to the fallback
runtime. Pi-owned tool effects are executed through the JavaScript host and
mapped back to canonical Posoco `ToolOutcome` values.

## Tool schema projection

Posoco core hard-fails agent composition when a catalog tool's input schema
uses any keyword outside its supported JSON Schema subset, while Pi tools
(TypeBox-based) freely use numeric constraints and unions. The adaptor
therefore projects every Posoco-visible tool schema (`src/schema_project.mbt`,
applied to tool `input_schema` and both catalog JSON views) down to a
whitelist:

- kept — `type` (string form), `description`, `properties` (projected
  recursively), `items` (object form projected, boolean kept), `required`,
  `enum`, `const`, `additionalProperties` (boolean kept, object form
  projected)
- dropped — unions (`anyOf`/`oneOf`/`allOf`) and every validation-only
  keyword (`minimum`, `maximum`, …)

Projection is lossy by design: the LLM-facing schema only steers argument
generation, and runtime argument validation stays with the Pi extension's own
TypeBox checks — tools receive raw arguments and validate them at execution
time. The projector never fails; unknown shapes pass through minus the keys
it does not know.

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

## System-prompt compatibility

Pi extensions can modify the prompt through several surfaces. The current
adaptor does **not** yet project these changes into Posoco's model request:

- tool-level `promptSnippet`
- tool-level `promptGuidelines`
- `pi.on("before_agent_start", ...)` returning `{ systemPrompt }`
- `resources_discover` contributions such as skills and prompt files
- `context` event message rewriting

The host currently preserves `promptSnippet` in its diagnostic catalog JSON,
but that is metadata only; it is not a Posoco `SystemPromptContributor`.
Likewise, a `before_agent_start` handler may be registered and visible through
the event registry, but Posoco does not automatically emit that event before a
model call.

This distinction matters when evaluating compatibility. A package may load and
register tools successfully while still losing instructions that are essential
to its documented behavior. Such a package is not marked fully compatible in
the matrix below.

A complete prompt bridge should eventually provide both:

1. a Posoco `SystemPromptContributor` for static tool prompt metadata; and
2. a runtime/model-boundary projection for chained asynchronous
   `before_agent_start` handlers, where each handler sees the prompt returned by
   the previous handler.

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

## Compatibility with representative Pi packages

The packages below were selected from the currently active Pi package ecosystem
and source-reviewed against the adaptor's exposed API surface.

Legend:

- ✅ **Verified compatible** — exercised with the unmodified package in the
  integration lab.
- 🟡 **Expected partial/core compatibility** — source reviewed and a useful
  headless subset maps to supported APIs, but the exact package has not been
  run end to end or some secondary behavior is unavailable.
- ❌ **Not currently compatible** — the package's primary documented behavior
  depends on Pi APIs that the adaptor does not project.

| Package | Status | Assessment |
| --- | :---: | --- |
| [`pi-web-access`](https://pi.dev/packages/pi-web-access) | ✅ | `pi-web-access@0.27.0` (npm latest at round time; bun-installed in the `~/.cetas/pi-packages` umbrella) was loaded unmodified. Verified at three levels: the cetas-js host loads it at runtime and a real agent turn calls `fetch_content` end to end (`smoke-pi.ts`, 4/4 — package loaded from `~/.cetas/pi-packages`, model-visible tool, executed call with non-empty result, clean turn/shutdown); the real-package probe `test/pi-web-access.test.mjs` passes 3/3 including a live `fetch_content` against a public URL; the fixture suite `test/host.test.mjs` passes 7/7 (multi-entry loading, trust propagation, Promise execution, `EffectId` cancellation, dynamic catalogs). Registered tools: `web_search`, `source_check`, `fetch_content`, `get_search_content`; live provider-backed search execution was not exercised (only live fetch). |
| [`gentle-engram`](https://pi.dev/packages/gentle-engram) | ❌ | Its `mem_*` tools may register and execute, but the package's memory protocol depends on chained `before_agent_start` system-prompt injection. It also uses `session_compact` recovery and `tool_execution_end` passive capture, neither of which is automatically projected. |
| [`pi-mcp-adapter`](https://pi.dev/packages/pi-mcp-adapter) | ❌ | Core initialization and dynamic operation use `pi.events`, flags, `getAllTools`, active-tool mutation, tool removal, commands and interactive UI. These are not presentation-only features for this package. |
| [`pi-subagents`](https://pi.dev/packages/pi-subagents) | ❌ | Its core is a child-Pi runtime with spawned processes, model/session control, background jobs, intercom, commands and TUI state. A registered-tool bridge cannot reproduce those semantics. |
| [`pi-fabric`](https://pi.dev/packages/pi-fabric) | ❌ | Depends on registered-tool interception, `pi.events`, active-tool ownership, context/message/tool middleware, compaction, child agents/actors and TUI controllers. |
| [`pi-mcp-extension`](https://pi.dev/packages/pi-mcp-extension) | ❌ | Dynamic server refresh relies on `getActiveTools` / `setActiveTools`; operational control is exposed through Pi commands and UI. The adaptor can record command registration but cannot execute those commands. |
| [`pi-soly`](https://pi.dev/packages/pi-soly) | ❌ | Its core workflow depends on `before_agent_start` prompt replacement, resource context, active-tool inspection, input/turn/tool hooks, session branch APIs, commands, skills and extensive UI projection. |
| [`@vigolium/piolium`](https://pi.dev/packages/%40vigolium%2Fpiolium) | ❌ | Primarily command-driven and built around sub-agent execution, provider/model access, flags, prompts, themes and rich UI. The current adaptor does not project those host capabilities. |

## Port-only mode

Using `PiAdaptor` only as a normal `ToolProvider` supports tools that return a
result synchronously. Promise execution, effect-correlated cancellation,
dynamic catalogs and background follow-up turns require `PiRuntime` through
`Agent::with_runtime`.

## Current boundaries

- system-prompt contributions and `before_agent_start` replacement are not yet
  projected into Posoco model calls.
- `onUpdate` payloads are captured and correlated, but the embedding host must
  project them to Posoco Observer or UI events.
- registered commands, shortcuts and renderers are recorded but are not yet
  projected into Posoco command/UI ports.
- automatic projection of `resources_discover`, `context`, `session_compact`,
  `tool_execution_end`, input, turn and message middleware events is not
  implemented.
- the headless UI does not provide interactive input, selection or
  confirmation.
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

The Node test fixture covers multi-entry package loading, trust propagation,
Promise execution, `EffectId` cancellation, follow-up capture and dynamic
catalog registration. The real-package probe `test/pi-web-access.test.mjs`
loads `pi-web-access` from `~/.cetas/pi-packages` and must run under Bun (it
skips when the package is absent or when Node cannot type-strip it).
