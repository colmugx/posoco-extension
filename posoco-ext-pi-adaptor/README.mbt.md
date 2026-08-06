# posoco-ext-pi-adaptor

`posoco-ext-pi-adaptor` is a JavaScript-target compatibility host for loading
Pi ecosystem extensions inside Posoco 0.9.

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

The current implementation has been exercised with an unmodified
`pi-web-access@0.18.0` package on Node.js 22.

## Supported profile

- JavaScript target only
- Node.js 22.6 or later; Bun-compatible ESM is expected
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

## Posoco 0.9 composition

`PiAdaptor` is a normal Posoco `Extension` and `ToolProvider`. Complete Pi
semantics use `PiRuntime` and `PiCatalogSource` with `Agent::with_runtime`:

```moonbit
let pi = @pi.PiAdaptor()
let port_runtime = @runtime.PortRuntime::new(
  model~,
  tools=ordinary_tool_routes,
)
let pi_runtime = @pi.PiRuntime::new(
  adaptor=pi,
  fallback=port_runtime as &@runtime.Runtime,
)
let catalog = @pi.PiCatalogSource::new(
  adaptor=pi,
  base_tools=ordinary_tool_defs,
)
let agent = @posoco.Agent::with_runtime(
  exts=extensions,
  config=agent_config,
  runtime=pi_runtime as &@runtime.Runtime,
  catalog_source=catalog as &@runtime.CatalogSource,
)

// Agent owns the run/turn mailbox, so attach its public control handle after
// construction.
pi_runtime.attach_control(agent.control())
```

`PiRuntime` delegates model calls, compaction and non-Pi tools to the fallback
runtime. Pi-owned tool effects are executed through the JavaScript host and
mapped back to canonical Posoco `ToolOutcome` values.

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

## Port-only mode

Using `PiAdaptor` only as a normal `ToolProvider` supports tools that return a
result synchronously. Promise execution, effect-correlated cancellation,
dynamic catalogs and background follow-up turns require `PiRuntime` through
`Agent::with_runtime`.

## Current boundaries

- `onUpdate` payloads are captured and correlated, but the embedding host must
  project them to Posoco Observer or UI events.
- registered commands, shortcuts and renderers are recorded but are not yet
  projected into Posoco command/UI ports.
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
catalog registration.
