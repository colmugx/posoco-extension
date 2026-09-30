# posoco-ext-board

`posoco-ext-board` is the browser-native orchestration surface for Posoco. It
is intentionally **not** a second Agent runtime: Posoco continues to own model
calls, tool execution, session state, cancellation and Agent task governance.

## Current status: S2B read-only realtime and reconnect

S0 established the independent wire protocol and in-memory telemetry sequence.
S1 adds the native localhost control plane and the user-facing Board commands.
S2A adds read-only Observer projection into the existing in-memory telemetry
history. S2B delivers that same sanitized history over authenticated native
WebSockets, with bounded client mailboxes and reconnect replay. It does **not**
persist Board domain state or execute Agent work.

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
- `/?token=...` — bounded text-only diagnostics, not a product UI.

The JavaScript target remains intentionally unsupported for the server;
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

For custom native adapter injection, construct one hub and pass it to **both**
the server and runtime. Their optional defaults allocate independent hubs;
`with_adapters` does not inspect or replace a server's hub. The default factory
already performs this shared wiring.

```mbt nocheck
let hub = @runtime.BoardEventHub(capacity=4096, client_queue_depth=256)
let server = @runtime.NativeBoardWebServer(hub~)
let runtime = @runtime.BoardRuntime::with_adapters(
  hub~,
  server~,
  opener=@runtime.NativeBrowserOpener(),
)
```

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

## Event projection (S2A)

The manifest registers one synchronous Observer and no PipelineHook. Projection
calls only `runtime.publish_telemetry`, always with `board_revision=0`; the hub
owns monotonic `seq`. No server attachment or startup is needed to record events.
`EventScope` IDs are explicitly copied into protocol-owned scope fields, without
normalizing or guessing IDs. Missing scope stays absent, including during a run.

| Posoco event | Board kind |
| --- | --- |
| TurnStarted / Completed / Failed | `run.started` / `run.completed` / `run.failed` |
| TextDelta / ReasoningDelta | `assistant.delta` / `assistant.reasoning_delta` |
| ToolCallPending / Succeeded | `tool.pending` / `tool.completed` |
| ToolCallFailed / Rejected / Abandoned | `tool.failed` |
| ModelResponseReceived | `model.response` |
| UserRequestStarted / Finished | `run.blocked` / `run.resumed` |
| StreamChunksDropped / ConfigWarning | `runtime.warning` |

Tool payloads contain the original `call_id`, a display `tool` name and a safe
`preview`. Pending/failure/rejection/abandonment previews are fixed labels;
success previews use sanitized content. Run failures and configuration warnings
use fixed labels, not raw error/configuration values. Warning codes are
`stream_chunks_dropped` (with `count`) and `config_warning`.
`model.response` contains only structured `usage`: absent usage is null, and each
missing token count is null, never synthesized as zero or summed into a total.
Other events (including tool approval/start and non-text stream chunks) are
ignored rather than duplicated.

Display fields first check the input length in O(1), before any copying,
scanning or normalization. Inputs exceeding **16384 UTF-16 code units** are
omitted entirely as `[truncated]`, never sampled for a prefix. At or below that
budget, filtering removes C0 controls (U+0000–U+001F) except tab (U+0009) and
newline (U+000A), DEL/C1 (U+007F–U+009F), bidi embedding/override controls
(U+202A–U+202E) and bidi isolate controls (U+2066–U+2069). Credential matching
happens after control removal, so controls cannot split a credential label.
Whole newline-delimited lines containing Authorization, api_key, apikey,
access_token, refresh_token, password or secret are then redacted,
case-insensitively, before display truncation. Output is capped at **1024 Unicode
characters**, including `...[truncated]` when that display cap is exceeded.
This intentionally over-redacts substring matches. Arguments,
structured tool results, attachments, full model messages and provider error
payloads are never serialized. Scope and call IDs are correlation identifiers,
not display text, and are preserved verbatim.

This is a per-event display filter, not a credential/DLP guarantee: labels split
across separate stream events, unlabeled credentials and arbitrary sensitive
prose are not detected. There is no cross-event buffering or current-run state.
Telemetry remains in the existing bounded history; S2A adds no WebSocket event
delivery, replay/reconnect logic, queues, UI, domain state, persistence, Tasks or
Agent execution. The existing S1 server lifecycle is unchanged.

## Realtime and reconnect (S2B)

The first WebSocket message must be a v1 text `Hello`, within 5 seconds and
8192 bytes. Cursors must be nonnegative JSON safe integers. Invalid Hello,
command-first and unsupported versions receive a small `error` frame and
close. Later commands return `accepted=false`,
`error="unsupported_in_current_stage"`, `current_revision=0`, without mutation.

Subscription computes bootstrap and registers the live mailbox synchronously:

- `last_seq == current_seq`: empty replay, including the empty `0/0` case;
- `last_seq == 0` with existing events: explicit snapshot reset;
- retained history covers the missing interval: ordered event replay;
- a history gap or future cursor: snapshot of `{ "events": retained_history }`.

Snapshots use `last_seq=current_seq` and `board_revision=0`; they contain only
the existing sanitized telemetry, not domain state. Initial frames are separate
from the live mailbox, so a large replay cannot overflow itself. The default
history capacity remains `event_buffer=4096`; each client has its own
`client_queue_depth=256` mailbox. Publishing only retains history and uses
synchronous `try_put`: no waiting, JSON stringification or network I/O.

Overflow makes that subscription terminal. The sender cancels and joins any
blocked write, best-effort sends `resync_required` with
`reason="client_queue_overflow"` and `current_seq`, then closes. If a fragmented
write was interrupted, another application frame is unsafe and the connection
closes without a resync frame. Writes have a 1-second deadline. All connection
exits unregister and close the mailbox; shutdown explicitly cancels local
connection tasks. No connection task outlives its structured scope.

The diagnostics page uses `textContent`, at most 100 lines of 512 characters,
and only status/seq/kind/scope. It replaces snapshots, ignores duplicate events,
resets on gaps/resync, stores only the cursor in `sessionStorage`, and reconnects
with 250ms–10s backoff. An empty replay displays “connected; hello sent”; there
is no fabricated snapshot or acknowledgement. Snapshot events must be a
contiguous retained suffix ending exactly at `last_seq`; an empty snapshot is
valid only at `last_seq=0`. Invalid snapshots reset the cursor and reconnect.
`pagehide` closes and detaches the socket and clears the reconnect timer;
persisted `pageshow` resumes once with the retained cursor. Late callbacks from
the old socket are ignored, and a protocol-error stop remains terminal.
The server remains native-only; protocol, replay and mailbox tests also run on JS.
Run the browser VM regressions from the extension workspace with
`moon run --target js --output-json posoco-ext-board/check_browser.mbtx`.
The `.mbtx` keeps lifecycle/snapshot test scenarios and assertions in MoonBit;
Node VM bindings simulate DOM, sockets and timers without a browser or server.

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

- root package: config, commands, lifecycle adapter and Observer projection;
- `protocol`: UI/server-independent JSON wire types and codecs;
- `runtime`: event history, server lifecycle, platform server/browser seams.

Later stages add the Board domain and persistence, then Agent execution without
changing these ownership boundaries.
