# posoco-ext-board

`posoco-ext-board` is the browser-native orchestration surface for Posoco. It
is intentionally **not** a second Agent runtime: Posoco continues to own model
calls, tool execution, session state, cancellation and Agent task governance.

## S0 status

Stage S0 establishes only the package boundary, wire protocol vocabulary,
minimal runtime facade and an in-memory event history. It does **not** start an
HTTP/WebSocket server, open a browser, persist Board state or execute an Agent.

The wire protocol is versioned independently from Posoco internals. It defines
`BoardHello`, `BoardClientCommand`, `BoardCommandResult`, `BoardWireEvent` and
`BoardSnapshot`; raw Posoco `TurnEvent` values are never exposed on the wire.
Transport `seq` and authoritative `board_revision` are distinct counters:
telemetry may advance `seq` without changing Board domain revision.

## Task vocabulary

The implementation keeps three task concepts separate:

- **BoardTask / Attempt** — product/business lifecycle. These arrive with the
  Board domain stage and are not implemented in S0.
- **Fuwaroid SupervisedTask** — ownership of Board runtime coroutines such as
  servers, pumps and top-level execution workers. S0 pins Fuwaroid but starts no
  worker.
- **Posoco TaskSpec / TaskHandle** — Agent-owned child/background work. The
  extension does not declare `Capability::Tasks` in S0.

These ids and lifecycles must never be treated as interchangeable.

## Concurrency policy

Board v1 will allow at most one active Agent run at a time. This is an
attribution correctness constraint, not a permanent UI limitation. S0 has no
Agent binding or scheduler yet, but the protocol and runtime skeleton do not
assume multi-run execution.

## S0 packages

- root package: extension/config shell only;
- `protocol`: UI/server-independent JSON wire types and codecs;
- `runtime`: pure in-memory event sequencing/history facade.

Later stages add the local control plane, reconnect, domain persistence and
Agent execution without changing these ownership boundaries.
