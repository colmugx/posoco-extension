# posoco-ext-mbtx

An experimental **MoonBit guest runtime for Posoco Code Mode**. Programs perform
computation and compose capabilities; MBTX is not a shell or a command runner.

This is a breaking replacement of the previous extension, not a compatibility
update. The old `MbtxTools`, `cmd`, command allowlist, prompt charter, permission
exemptions and sandbox escalation APIs are gone.

## What is implemented

- A host `Runtime` that compiles programs without executing them, caches
  artifacts, and launches a short-lived Wasm guest for each invocation.
- A bounded, versioned, bidirectional JSON protocol over stdio.
- A guest SDK with `Context`, injectable `ToolClient`, structured `Outcome` and logs.
- Native and Node-compatible JS host adapters, including cancellable I/O,
  terminate/hard-kill/reap, and scoped temporary-workspace cleanup.

**What is not implemented:** Posoco-scoped tool invocation, Agent tool
registration, Plugin Mode, dynamic catalog integration, or the Cetas plugin
manager. No `ToolProvider` or `Extension` is registered by this package yet.

`ToolInvoker` is a trusted host integration seam for the future Posoco adapter,
not a governance implementation. Tests use explicit fakes. Production code must
not implement this seam by directly calling a `ToolProvider`, duplicating the
permission pipeline, or fabricating child effects. Without an adapter, an
otherwise permitted tool request returns `ToolInvocationUnavailable`.

## Package boundaries

| Package | Responsibility |
|---|---|
| `colmugx/posoco-ext-mbtx` | Host runtime, build/cache, process lifecycle, invocation bridge |
| `colmugx/posoco-ext-mbtx/protocol` | Framing, messages, structured outcomes and host protocol state machine |
| `colmugx/posoco-ext-mbtx/sdk` | Guest-facing Context and injectable ToolClient/LogSink |
| `colmugx/posoco-ext-mbtx/sdk/stdio` | Guest stdio transport and `serve` |

The SDK does not depend on Posoco, its Kernel, or the host runtime. The current
wire protocol number is 1, but the ABI remains experimental until the real
Posoco adapter has been integrated and verified.

## Guest program

The current builder accepts ordinary MoonBit declarations defining this handler:

```mbt nocheck
async fn run(ctx : @sdk.Context, input : Json) -> @sdk.Outcome {
  ctx.log("info", "computing")
  let values = [1, 2, 3]
  let sum = values.fold(init=0, (a, b) => a + b)
  @sdk.Outcome::Success(
    content="computed",
    structured=Some({ "sum": sum, "input": input }),
  )
}
```

The host supplies the entry point calling `serve(run)` and owns the build
manifest. This is not the legacy arbitrary `.mbtx` main-program interface.
Available package aliases are `@sdk`, `@mbtx` (stdio), `@protocol`, `@async` and
`@json`, plus the MoonBit prelude. Guest code does not choose dependencies or
supply build hooks.

To compose a tool, the handler uses `ctx.call(name, arguments)`. Its result is a
structured `Outcome`, not parsed stdout. Several calls can be awaited with normal
MoonBit structured concurrency. Requests outside the effective tool-name set
return `CapabilityDenied`; a closed Context returns `ScopeClosed`. The host
checks the effective tool-name set again before dispatch. These checks are
attenuation, not a replacement for Posoco governance.

Normal guest code should not write stdout; use `ctx.log`. Unframed debug output
is a protocol error, never an implicit successful result.

## Host lifecycle

The host provisions trusted SDK sources and the already-installed
`moonbitlang/async@0.22.4` source tree. There is no installation or dependency
download during an invocation. `moon` and `moonrun` must be available to the host;
explicit executable paths can be supplied to the constructor.

Illustrative host code (the paths are relative to this module in the workspace):

```mbt nocheck
let runtime = @mbtx.Runtime(
  sdk_source_root="src",
  async_source_root="../.mooncakes/moonbitlang/async",
)
let artifact = runtime.build(source)
let result = runtime.run(artifact, input, invocation_id="operation-1")
// Consume result.outcome, result.logs and result.stderr.
runtime.close()
```

Real hosts must put `close()` in protected cleanup. `cancel(invocation_id)` requests
cancellation; the caller must still join the running `run()` call. Cancellation
closes the invocation, not the Runtime. Retrying after cancellation or timeout is
supported. There is no automatic replay of partially completed workflows.

`clear_cache()` is allowed only while no invocation is active. It invalidates
existing Artifact handles. `close()` closes admission and clears artifacts;
callers must cancel and join active invocations first. Filesystem cleanup errors
are surfaced, not silently swallowed; a failed cache cleanup closes admission
and can be retried with `close()`.

## Build/cache contract

The builder creates a host-owned workspace containing the program, SDK and a
snapshot of the prepared async dependency. It invokes `moon run --build-only`
with `--frozen --target wasm --output-json`; it never runs the guest during build.
The toolchain and provisioned SDK/dependency roots are trusted host inputs, not
paths supplied by the guest.

Cache lookup compares an exact content descriptor, not a collision-prone hash:
program, SDK sources/manifests, dependency sources/manifests, reported MoonBit
and moonrun versions, generated build configuration, target and protocol number.
The installed toolchain/core library is assumed immutable for a given reported
version. Successful builds are published only after an artifact is reported;
failed/cancelled builds are cleaned and cannot poison a ready artifact.

The cache is instance-scoped (not a persistent cross-restart cache), holds at
most 16 artifacts, and requires explicit idle cleanup when full. Artifact
handles pin their implementation; invocation permissions are supplied separately
and are never cached as build authorization. Builds are serialized; build timeout
starts after acquiring the build slot. Source is limited to 1 MiB.

## Isolation and limits

Guest target: **Wasm only**. Host targets: **native and JS**. These are separate
choices; a JS host still runs the guest under moonrun, not as JavaScript.

The generated moonrun policy denies guest filesystem read/write, network,
process spawning and host-environment inheritance. There is no process API or
sandbox-bypass option in the SDK. Host compiler/launcher subprocesses are runtime
implementation details, not capabilities of the program. The JS launcher keeps
only host PATH for executable resolution; guest environment access is still
denied by the policy.

| Limit | Default |
|---|---:|
| Build timeout (after admission) | 30 seconds |
| Invocation wall clock | 120 seconds |
| Handshake timeout | 5 seconds |
| Frame size | 64 KiB (also the maximum accepted configuration) |
| Concurrent pending tool requests | 8 |
| Total tool requests per invocation | 128 |
| Combined stdout/stderr bytes | 1 MiB |
| Process termination grace before hard kill | 1 second |

Limits fail closed; protocol bytes are not truncated into apparently valid
messages. There is not yet a separate OS-enforced memory quota or CPU-fuel limit.
The runtime does not support persistent workers, detached guest jobs, arbitrary
guest imports, workflow checkpoint/resume, or plugin installation.

## Protocol

Transport is UTF-8 JSON with **one complete JSON object per LF-delimited frame**.
Frame limits count bytes, not characters. JSON strings carry escaped newlines.
stdout is protocol-only; stderr is a separate bounded diagnostic stream.

```text
Starting → Handshaking → Running → Closing → Terminated

Guest → Host: hello(protocol)
Host → Guest: invoke(input, tools, max_pending, max_frame_bytes)
Guest → Host: request(id, name, arguments)   ┐ multiple requests may be in flight
Host → Guest: reply(id, outcome)            ┘
Guest → Host: log(level, content)
Guest → Host: result(outcome)
Host → Guest: cancel(reason)                (SDK-supported control message)
```

Host cancellation currently tears down the process scope directly; it does not
rely on a cooperative guest cancel acknowledgement. Ordinary JS I/O waits use
AbortSignal-aware promises so cancellation reaches the process cleanup. Only the
protected termination/reap wait is deliberately non-cancellable.

Invalid UTF-8/JSON, unknown message types, version mismatch, duplicate request
IDs, excess pending/total requests, replies without correlation, partial EOF,
messages after final result and final result with pending requests are rejected.
An exit code of zero without a final result is failure. A result is accepted only
after process exit and scope settlement. A present structured JSON null remains
distinct from an absent `structured` field.

## Verification

From the workspace root:

```bash
moon -C external/cetas/extension/posoco-ext-mbtx check --target native --output-json
moon -C external/cetas/extension/posoco-ext-mbtx check --target js --output-json
moon -C external/cetas/extension/posoco-ext-mbtx check --target wasm --output-json
moon -C external/cetas/extension/posoco-ext-mbtx test --target native -p colmugx/posoco-ext-mbtx -p colmugx/posoco-ext-mbtx/protocol -p colmugx/posoco-ext-mbtx/sdk --output-json
moon -C external/cetas/extension/posoco-ext-mbtx test --target js -p colmugx/posoco-ext-mbtx -p colmugx/posoco-ext-mbtx/protocol -p colmugx/posoco-ext-mbtx/sdk --output-json
```

The runtime tests compile and run actual guests. The tool bridge tests use fakes
and do **not** certify Posoco permissions, effect trees or scheduling. Those
integration tests belong to the future scoped-invocation adapter milestone.
