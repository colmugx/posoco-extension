# posoco-ext-mbtx

An experimental **MoonBit guest runtime for Posoco Code Mode**. MBTX executes
programs, not shell commands. Plugin Mode and Posoco-scoped tool invocation are
not implemented; this package does not register an Extension or ToolProvider yet.

## Automatic MoonBit toolchain provisioning

No host-side toolchain setup is required. A default Runtime first probes a
working \`moonx\` or \`moon\`/\`moonrun\` on PATH, then under the official
\`~/.moon/bin\` directory. If neither works, it reuses or installs a private
MoonBit toolchain under \`~/.cetas/moon_toolchain/current\`.

The managed version is pinned by \`MBTX_TOOLCHAIN_VERSION\`; installation uses
the official HTTPS MoonBit installer in an isolated \`MOON_HOME\`, checks the
compiler version, and refuses to publish failed or partially installed stages.
A file lock prevents competing host processes from installing simultaneously.
The first call requiring MBTX may need network access and an available
\`curl\`/PowerShell or Bash executable. A cached toolchain works offline when
guest dependencies are also cached.

The Runtime supports a \`bus\` keyword argument. When provided, it publishes
\`mbtx: checking/downloading/initializing/verifying\` on the existing devkit
status bus and unregisters the segment on success. The optional Posoco
\`MbtxExtension\` exposes a read-only \`/mbtx status\` command.

For isolated testing or forced managed installation, pass \`prefer_system=false\` to Runtime or MbtxExtension. Explicit custom launcher paths retain their previous behavior without automatic
installation. The guest SDK imports are still resolved through MoonBit, not
bundled by the host. Guest call frames are handed to the caller's `on_call`
handler; Posoco governance integration lives in posoco-ext-ptc, not here.

## Host API

```mbt nocheck
let runtime = @mbtx.Runtime()
let result = runtime.run(source, input, invocation_id="operation-1")
// Consume result.outcome, result.logs and result.stderr.
runtime.close()
```

`run` accepts a **complete `.mbtx` script**, including its import block and main.
It no longer accepts a handler fragment or an Artifact handle. The old `build`,
`clear_cache`, `Artifact` and dependency-source-root constructor arguments are gone.

`run_file(path, input, invocation_id=...)` executes an existing `.mbtx` file.
With the explicit Moon launcher it also accepts a local main package or an
already-built Wasm artifact. It does not discover or register plugin tools.

Hosts must close the Runtime in cleanup after joining active calls. Calling
`cancel(invocation_id)` requests cancellation; the caller must still join that
`run` or `run_file` call. Cancellation ends the invocation, not the Runtime.
`close()` is synchronous, closes admission, and refuses while calls are active.
There is no automatic replay or rollback of effects.

## Guest SDK: normal MoonBit packages

The SDK is imported like any other MoonBit package. A complete script looks like
this **once a compatible SDK module version is available through Mooncakes**:

```mbt nocheck
import {
  "colmugx/posoco-ext-mbtx@0.1.0/sdk",
  "colmugx/posoco-ext-mbtx@0.1.0/sdk/stdio" @mbtx,
  "moonbitlang/async@0.22.4",
}

async fn run(ctx : @sdk.Context, input : Json) -> @sdk.Outcome {
  ctx.log("info", "computing")
  @sdk.Outcome::Success(content="done", structured=Some(input))
}

async fn main {
  @mbtx.serve(run)
}
```

The new SDK ABI in this checkout has not been published by this change. The
example is not a claim that the registry currently contains that ABI. Local SDK
integration tests use a normal `moon.work` dependency on this module and compile
their test main package normally; they do not copy SDK or third-party sources.
Runtime itself has no SDK file list, SDK version pin, or SDK source path.

| Package | Responsibility |
|---|---|
| `colmugx/posoco-ext-mbtx` | Host invocation, runner selection and process lifecycle |
| `colmugx/posoco-ext-mbtx/protocol` | Framing, outcomes and host protocol state machine |
| `colmugx/posoco-ext-mbtx/sdk` | Context, injectable ToolClient/LogSink |
| `colmugx/posoco-ext-mbtx/sdk/stdio` | `serve` and private fuwaroid request registry |

The SDK does not depend on Posoco's Kernel or host Runtime. Fuwaroid is an ordinary
SDK implementation dependency, not a source directory passed to Runtime. Its
single-writer registry owns request ids, pending waiters and settlement; I/O stays
on structured tasks outside the actor. Unknown or duplicate replies fail explicitly.

`ctx.call(name, arguments)` returns a structured Outcome. Requests outside the
effective tool-name set return `CapabilityDenied`. Without an `on_call`
handler, otherwise allowed calls return `ToolInvocationUnavailable`.

The `on_call` handler is a trusted integration seam, **not** a governance
implementation: the runtime is tool-agnostic and only forwards call frames.
Do not implement it by directly calling a ToolProvider or fabricating child
effects — the governed seam (`ToolInvoker`) lives in posoco-ext-ptc. Tests
use fakes and do not certify Posoco permissions or scheduling.

## Protocol, isolation and limits

Guests run as linear-memory Wasm; host targets are native and Node-compatible JS.
The host supplies a deny-by-default policy for guest filesystem, network, process
spawning and environment access. Script-embedded policy does not replace it.
The compiler/runner inherits its normal host environment to resolve dependencies;
**guest execution policy does not sandbox compilation or dependency build hooks**.
Toolchains and dependencies must be trusted. This is not a hermetic build service.

Transport is bounded UTF-8 JSON, one complete object per LF-delimited frame.
stdout is protocol only; stderr is collected separately. Use `ctx.log`, not println.

```text
Guest → Host: hello(protocol)
Host → Guest: invoke(input, tools, max_pending, max_frame_bytes)
Guest → Host: request(id, name, arguments)
Host → Guest: reply(id, outcome)
Guest → Host: log(level, content)
Guest → Host: result(outcome)
```

Multiple requests may be in flight. Invalid framing/UTF-8/JSON, unknown or duplicate
ids, result-with-pending-requests, partial EOF and successful exit without a final
result are errors. Results are accepted only after process exit and scope
settlement. Structured JSON null remains distinct from an absent field.

| Limit | Default |
|---|---:|
| Entire invocation, including runner probe and compilation | 120 seconds |
| Initial hello (includes compilation for Moonx) | 30 seconds |
| Source size | 1 MiB |
| Frame size | 64 KiB, also maximum configurable size |
| Pending tool requests | 8 |
| Total tool requests | 128 |
| Combined protocol stdout/stderr | 1 MiB |
| Compiler/probe output collection | 1 MiB per command |
| Termination grace before hard kill | 1 second |

Moon compile failures report `BuildFailed`. Moonx combines compilation and
execution, so a failed launcher reports `GuestFailure` with its stderr, including
compiler diagnostics. EOF before hello is reported immediately rather than
waiting out the handshake timeout. Compiler/probe output has its own collection
budget; guest protocol bytes are never silently truncated.

There is no separate OS-enforced memory quota or CPU fuel budget. Persistent
workers, detached services, workflow recovery, dynamic tool registration and
Plugin Mode remain outside this implementation. No Posoco core changes are needed
or made by this runtime refactor.

## Verification

From the workspace root:

```bash
moon -C external/cetas/extension/posoco-ext-mbtx check src src/protocol src/sdk src/sdk/stdio --target native --output-json
moon -C external/cetas/extension/posoco-ext-mbtx check src src/protocol src/sdk src/sdk/stdio --target js --output-json
moon -C external/cetas/extension/posoco-ext-mbtx check src/protocol src/sdk src/sdk/stdio --target wasm --output-json
moon -C external/cetas/extension/posoco-ext-mbtx test --target native -p colmugx/posoco-ext-mbtx -p colmugx/posoco-ext-mbtx/protocol -p colmugx/posoco-ext-mbtx/sdk -p colmugx/posoco-ext-mbtx/sdk/stdio --output-json
moon -C external/cetas/extension/posoco-ext-mbtx test --target js -p colmugx/posoco-ext-mbtx -p colmugx/posoco-ext-mbtx/protocol -p colmugx/posoco-ext-mbtx/sdk --output-json
moon -C external/cetas/extension/posoco-ext-mbtx test --target wasm -p colmugx/posoco-ext-mbtx/sdk/stdio --output-json
```

Runtime tests require both installed runners to verify both launch paths. SDK
fixtures are ordinary local packages; standalone runner fixtures import the
released async module normally and exercise real Wasm execution.

## Incremental build cache

A configured PTC extension reuses a stable compiler cache at
`~/.cetas/ptc_build_cache` (overridable with `build_cache`).
MBTX serializes builds within its Runtime, retains source mtimes on exact
matches, and copies each finished Wasm artifact into a private invocation
directory. No guest results, policies or tool outputs are cached.
The fallback `moonx`-only execution path remains supported.
