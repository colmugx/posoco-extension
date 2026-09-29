# posoco-ext-board

`posoco-ext-board` is the browser-native orchestration surface for Posoco. It
is intentionally **not** a second Agent runtime: Posoco continues to own model
calls, tool execution, session state, cancellation and Agent task governance.

## Current status: S1 local control plane

S0 established the independent wire protocol and in-memory telemetry sequence.
S1 adds the native localhost control plane and the user-facing Board commands.
It still does **not** observe Agent turns, persist Board domain state or execute
Agent work.

The native backend binds exactly `127.0.0.1:0`: the OS selects an available
loopback port. Each listener instance receives a fresh 256-bit secret from the
OS entropy source. The secret is process-local, never persisted and never
returned by `/health`, `/api/bootstrap` or `board.status`. The browser
bootstrap URL carries the secret, and protected HTTP/WebSocket requests must
present it. WebSocket upgrades also enforce loopback Host and same-origin
checks when Origin is present.

S1 routes are:

- `/health` — token-free liveness only;
- `/api/bootstrap?token=...` — protocol/endpoint metadata, never the token;
- `/ws?token=...` — authenticated WebSocket upgrade;
- `/?token=...` — minimal placeholder page until the product UI stage.

The JavaScript target remains intentionally unsupported for the server in S1;
it still compiles against the same runtime abstraction.

## Host wiring

Board server work is long-lived and must belong to the host's structured
concurrency scope. Attach the extension to the host task group before invoking
`/board`:

```mbt nocheck
let board = @board.BoardExtension::BoardExtension()
let agent = @posoco.Agent(
  exts=[board, model_ext, session_ext],
  config,
)

@async.with_task_group(group => {
  board.attach(group)

  // Run the host/agent loop here. Invoking /board now starts the listener
  // lazily and opens the authenticated bootstrap URL.
})
```

`attach(group)` in S1 owns Board runtime workers only. It does not bind an
Agent and does not grant `Capability::Tasks`; Agent binding and execution are
introduced in a later stage.

## Commands

The extension contributes three commands:

- `board.open` — alias `board` for slash-style hosts; lazily start/reuse the
  control plane and open/focus the browser page;
- `board.status` — token-free control-plane status;
- `board.close` — idempotently stop the current listener.

Lifecycle startup does not open a browser. Lifecycle shutdown closes the
listener and settles supervised runtime work.

## Wire protocol

The wire protocol is versioned independently from Posoco internals. It defines
`BoardHello`, `BoardClientCommand`, `BoardCommandResult`, `BoardWireEvent`
and `BoardSnapshot`; raw Posoco `TurnEvent` values are never exposed on the
wire. Transport `seq` and authoritative `board_revision` are distinct
counters: telemetry may advance `seq` without changing Board domain revision.

## Task vocabulary

The implementation keeps three task concepts separate:

- **BoardTask / Attempt** — product/business lifecycle. These arrive with the
  Board domain stage and are not implemented in S1.
- **Fuwaroid SupervisedTask** — ownership of Board runtime coroutines. In S1 it
  owns the local server worker through the host TaskGroup.
- **Posoco TaskSpec / TaskHandle** — Agent-owned child/background work. The
  extension does not declare `Capability::Tasks` in S1.

These ids and lifecycles must never be treated as interchangeable.

## Concurrency policy

Board v1 will allow at most one active Agent run at a time. This is an
attribution correctness constraint, not a permanent UI limitation. S1 does not
run Agents yet, so the local control plane introduces no second execution
scheduler.

## Packages

- root package: config, commands and lifecycle adapter;
- `protocol`: UI/server-independent JSON wire types and codecs;
- `runtime`: event history, server lifecycle, platform server/browser seams.

Later stages add event projection/reconnect, the Board domain and persistence,
then Agent execution without changing these ownership boundaries.
