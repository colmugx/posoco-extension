# posoco-ext-ptc

Programmatic Tool Calling for Posoco, using `posoco-ext-mbtx` as a private MoonBit Wasm guest runtime.

This is a real `run_code` ToolProvider with stable SystemPromptContributor, an automatically generated MoonBit guest wrapper, an explicit nested-call capability list, bounded final output and effect cancellation. No LLM-side selection is needed *within a PTC agent*: the manifest exposes exactly one model tool. Do not also compose the original end-tool extensions into the same PTC agent.

## Scope / security

**This release is a functional but *not yet Kernel-governed* PTC transport.** Posoco 0.22.1 `ToolCallContext` exposes no scoped tool-dispatch method, and `CompositionView` explicitly excludes raw tool invocation because it would bypass `PipelineHook::before_tool`. This package does not bypass that guard. By default the nested-tool bridge is absent, and attempts to call an allowed tool return `ToolInvocationUnavailable`; pure programs work without a bridge.

`scoped_invoker` is an explicit injection point for a future Posoco Core governed tool-call port. Test doubles demonstrate transport and capability enforcement; they do NOT certify Kernel permissions, audit/effect attribution or replay semantics. **Do not inject raw ToolProviders or a manually rebuilt permission engine as scoped_invoker.** A complete production PTC integration requires a new Kernel-scoped nested tool capability in Posoco, followed by a Cetas PTC agent recipe.

## Model interface

The model sees only `run_code({code, description, input?})` and the stable generated system prompt. Code is the body of a MoonBit async function:

```moonbit
// run_code.code, no imports or main:
let value = ctx.call("read", {"file_path": "README.md"})
match value {
  {"error": String(reason), ..} => {"error": reason}
  _ => {"summary": value}
}
```

The guest wrapper imports only official `moonbitlang/async@0.22.5` packages, not the unreleased MBTX SDK ABI, so a fresh compiler can build it. The wrapper serializes nested calls through one stdin/stdout channel: loops and intermediate filtering work today, but nested calls are not parallelized yet. Guest filesystem/network/process are denied by the MBTX Wasm policy. Compile-time MoonBit package hooks are not subject to the guest sandbox.

Supply-chain caveats from the stacked MBTX auto-provisioning PR apply to the first compiler installation.

## Developer composition

```moonbit
let ptc = @ptc.PtcExtension(
  exposed=approved_tool_definitions,
  // scoped_invoker must be Kernel-governed; not a raw provider.
  scoped_invoker=kernel_scoped_invoker,
  bus=event_bus,
)
let exts : Array[&@posoco.Extension] = [ptc]
```

The `exposed` definitions drive only prompt discoverability and the MBTX guest allow-list. The injected invoker is still responsible for authoritative per-call policy and scheduling.

## Verification

```sh
moon check --target native
moon check --target js
moon test --target native -p colmugx/posoco-ext-ptc --output-json
moon test --target js -p colmugx/posoco-ext-ptc --output-json
```

Tests cover manifest tool presentation, stable SDK prompt, actual MoonBit guest program execution, tool-call transport with fake invoker, fail-closed no-invoker and invalid code, across Native and JS.

## Complete script / official guest SDK

In addition to the inline \`code\` function-body form, \`run_code\` now accepts
\`source\` for a whole \`.mbtx\` program, including explicit imports and \`main\`.
This is the supported path for ordinary reusable MoonBit programs. It is
executed by the same MBTX runtime with the same tool allow-list and policy.
Use \`colmugx/posoco-ext-mbtx/sdk/stdio\` \`serve(run)\` and
\`colmugx/posoco-ext-mbtx/sdk\` \`Context\`. Unlike the simple body form, the
official SDK implements asynchronous request/reply multiplexing and allows
normal script source locations. Do not mix \`source\` and \`code\` in one call.
