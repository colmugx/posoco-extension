# posoco-ext-board

`posoco-ext-board` is the browser-native orchestration surface for Posoco. It
is intentionally **not** a second Agent runtime: Posoco continues to own model
calls, tool execution, session state, cancellation and Agent task governance.

## Current status: S3B2B2 runtime command handler and WebSocket commands on top of S3B2B1

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

`attach(group)` owns the Board server supervisor and durable coordinator
workers. It does not bind an Agent or grant `Capability::Tasks`; Agent binding
and execution are introduced in a later stage.

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
close. Commands are answered through the command handler seam introduced in
S3B2B2 (see below); a server without an installed handler keeps answering
`accepted=false`, `error="unsupported_in_current_stage"` without a
`current_revision`, and never mutates.

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
The page is a passive observer: it never sends commands, so `command_result`
frames — which are addressed only to the commanding connection — never arrive,
and any unrecognized frame is ignored without advancing the cursor. It keeps
its Board baseline across telemetry-only reconnects, and any `board.*` event
invalidates that baseline, so the next reconnect Hello reports
`has_board_snapshot=false` and receives a fresh authoritative snapshot. It is
bounded text-only diagnostics, not a product UI.
The server remains native-only; protocol, replay and mailbox tests also run on JS.
Run the browser VM regressions from the extension workspace with
`moon run --target js --output-json posoco-ext-board/check_browser.mbtx`.
The `.mbtx` keeps lifecycle/snapshot test scenarios and assertions in MoonBit;
Node VM bindings simulate DOM, sockets and timers without a browser or server.

## Board domain and coordinator (S3A)

S3A adds a pure Board domain (`domain`) and a single-writer coordinator
(`coordinator`). The domain owns no clock, no randomness, no IO and no JSON:
every command carries its expected revision plus explicit ids and timestamps,
and `BoardDomain::propose(state, command)` either returns a fully detached
successor state with ordered typed events, or a typed rejection that leaves
the input state untouched. Accepted mutations advance the revision by exactly
one. Stage moves follow one central table: Created→Refining/Suspended;
Refining→Ready/Suspended; Ready→Running/Refining/Suspended;
Running→Review/Suspended; Review→Done/Ready/Refining/Suspended; Done→Refining;
Suspended→Created/Refining/Ready. Entering Ready stamps `ready_since_ms` and
leaving clears it; Ready never requires dependencies to be Done. Dependencies
are validated for existence, self-reference, duplicate edges and DAG cycles.
Attempts run Queued→Running→{Succeeded,Failed,Cancelled,Interrupted} with
`started_at_ms`/`finished_at_ms` stamped by their own commands; Review attempts
start implicitly Pending and accept exactly one Approved/ChangesRequested.
Execution-specific invariants (Running↔Attempt↔stage coupling) are deferred to
S4 by design.

## Durable coordinator (S3B2A)

The coordinator's synchronous Fuwaroid handlers own committed state, one
pending candidate, and FIFO deferred submissions. Store IO belongs exclusively
to a Supervisor bound to the host TaskGroup; workers report settlement through
actor messages. **Persist before commit:** queries see only committed state,
and a submission succeeds only after its matching persistence ticket succeeds.
Deferred commands are proposed against the latest committed state only after
the previous transaction settles. A failed write before snapshot replacement
leaves state and revision unchanged, so a queued command can still use the old
expected revision. Commands and query results are deep detached.

`attach(group)` remains synchronous and starts asynchronous load/recovery.
Call `wait_ready()` before querying the domain API; loading queries return an
explicit initialization error rather than a fabricated empty board. Submissions
received during loading or reconciliation queue until settlement.
Startup uses S3B1 `load_recover_persist`: Running tasks become Suspended and
Running attempts become Interrupted, with the recovered revision durable before
readiness. Corruption and failed recovery writes fail initialization. Snapshot
restoration validates structure and preserves revision without creating mutations.

The native default uses `FileBoardStore(root=".")`; adapter injection and JS
use `MemoryBoardStore`. A minimal `now_ms` function supplies recovery time;
native defaults use real time, while tests supply deterministic values.
Read-only realtime `/board` telemetry remains usable independently of domain
initialization.

A post-rename `DurabilityUncertain` triggers reconciliation, never an assumed
rollback. Reload matching the candidate makes it committed; reload matching
the previous snapshot preserves it. In both cases the caller receives a typed
uncertainty error and must refresh. An unexpected snapshot or reload failure
makes the coordinator failed/read-only. Shutdown closes submission admission,
settles active IO and explicitly rejects deferred submissions before closing
and joining the actor, then shuts down its Supervisor. Cancelling a submit
waiter does not cancel an already accepted transaction.

Explicitly out of scope for S3B2A itself: authoritative domain EventHub
publication, Board domain wire snapshots, Agent execution, scheduler, UI,
Posoco Tasks and GitHub Actions changes. Telemetry `seq` and Board revision
remain independent; WebSocket commands still answered
`unsupported_in_current_stage` at this stage — S3B2B2 wires the runtime
command handler below.

## Runtime streaming and authoritative snapshots (S3B2B1)

The runtime is the only place where the durable coordinator and the telemetry
hub meet; the hub never learns about the coordinator and the coordinator never
learns about the hub. The runtime installs a synchronous `on_commit` hook that
projects every committed domain event into the same hub through
`@protocol.project_event`: the projected kind and payload carry the committed
revision, `seq` stays zero (the hub mints the transport sequence) and `scope`
stays absent, because a domain commit carries no Posoco attribution. Telemetry
projection is unchanged and keeps revision 0. A gated persist publishes
nothing; an uncertain persist publishes its events exactly once when — and only
when — the reconciliation adopts the candidate; a reload that keeps the prior
board leaves the stream untouched. Startup recovery streams its recovery
mutations once, and an unchanged load streams nothing.

`BoardCoordinator::stream_cursor` stores a callback that supplies the committed
event-stream position on demand; the runtime configures it to the hub head, and
`stream_snapshot` evaluates it synchronously on the loop while the committed
state is copied, so the answered `BoardStreamSnapshot` boundary is the actual
hub position — telemetry included — at query time. The runtime's
`bootstrap_snapshot` composites the authoritative wire snapshot from that exact
boundary: `last_seq` is `stream.stream_seq` (never a later hub head), the board
payload comes from `@protocol.snapshot_to_json` and `events` are every retained
hub event up to and ending exactly at the boundary
(`BoardEventHub::history_through`). Loading gates the bootstrap through
`wait_ready`; telemetry and the `/board` control plane stay live meanwhile.
A boundary whose retained suffix was evicted is never served: the bootstrap
retries with a fresher boundary a bounded number of times and then answers
`history_overflow`; a coordinator that is not ready answers
`snapshot_unavailable`. No fabricated or empty snapshot is ever produced, and
no store detail reaches the wire.

`BoardEventHub::subscribe` registers synchronously and returns an explicit
plan: `Live` (cursor at the head, including the empty `0/0` case), `Replay`
(the contiguous retained suffix after the cursor) or `SnapshotRequired` (zero
with events, a gap, an evicted history or a future cursor). The hub never
fabricates a snapshot. The server fulfils `SnapshotRequired` through the
runtime-installed snapshot provider — a `BoardWebServer` trait method with a
no-op default — after registration, so live events accumulate in the mailbox
while the coordinator settles; the installed snapshot carries the boundary and
the subscription drops stale mailbox events at or before it. A server without
a provider, like a failed bootstrap, answers one explicit `resync_required`
frame (`snapshot_unavailable`) and closes. Client mailboxes still overflow to
a terminal `client_queue_overflow` resync. WebSocket domain commands still
answered `unsupported_in_current_stage` at this stage; S3B2B2 adds the
runtime command handler below.

## WebSocket commands and the runtime handler (S3B2B2)

`BoardWebServer` gains `set_command_handler`, taking
`async (BoardClientCommand) -> BoardCommandResult` with a no-op default —
symmetric to `set_snapshot_provider`. The runtime installs exactly one
handler, `BoardRuntime::handle_command`, while starting the control plane. A
server without an installed handler — for example a custom native adapter
wired without the runtime — keeps answering every decoded `Command` with
`accepted=false`, `error="unsupported_in_current_stage"` and no
`current_revision`; that fallback mutates and publishes nothing. The
server only parses the frame and forwards: the decoded `Command` is handed to
the installed handler and the returned `CommandResult` is enqueued through
the existing bounded per-client mailbox. The result is delivered only on the
issuing connection and never enters EventHub history; gate-protected
lifecycle, Hello/security checks, snapshot bootstrap and overflow resync are
unchanged. Every domain timestamp is stamped by the runtime from its own
`now_ms` — clients never send clocks.

Eight commands are accepted, each keyed by `expected_revision` for optimistic
concurrency and using the stable `board.*` wire names decoded in `protocol`:

| Command | Args |
| --- | --- |
| `board.task.create` | `id`, `title`, `description`, `priority`, `definition_of_done`, `dependencies` (all required) |
| `board.task.update` | required `id`; optional `title`, `description`, `priority`, `definition_of_done` |
| `board.task.set_dependencies` | `id`, `dependencies` |
| `board.task.move` | `id`, `to` |
| `board.attempt.queue` | `id`, `task_id`, `kind` |
| `board.attempt.start` | `id` |
| `board.attempt.finish` | `id`, `outcome` |
| `board.review.record` | `id`, `decision` |

Every `args` must be an object. IDs and text fields are strings;
`definition_of_done` and `dependencies` are string arrays. Task and attempt IDs
are explicitly client-provided. Update fields omitted from args remain unchanged;
present fields must have the correct type, and explicit `null` is rejected.
`definition_of_done: []` explicitly clears DoD; dependencies change only through
`board.task.set_dependencies`.

Enum strings are fixed: `priority` = `low | normal | high | critical`;
`to` = `created | refining | ready | running | review | done | suspended`;
`kind` = `discuss | execute | review`;
`outcome` = `succeeded | failed | cancelled | interrupted`;
`decision` = `approved | changes_requested` (never `pending`).
`expected_revision` stays at frame top level, and `at_ms`, `revision`, persistence
metadata and every other unknown args field are rejected. The pure decoder
receives `at_ms` explicitly from the runtime's injected `now_ms` seam; it never
reads a clock or duplicates domain validation.

Fields are strict: unknown names and missing required fields are rejected,
and `args` are never reflected back. Rejections use stable wire codes —
`invalid_command` (empty `command_id` or unknown name),
`invalid_arguments` (malformed args), `revision_conflict`,
`task_not_found`, `attempt_not_found`, `invalid_transition`,
`invalid_attempt_transition`, `invalid_review_transition`,
`dependency_not_found`, `self_dependency`, `duplicate_dependency`,
`dependency_cycle`, `duplicate_task`, `duplicate_attempt`, `invalid_input`,
`board_initializing`, `board_unavailable`, `board_timeout`,
`persistence_failed` and `durability_uncertain` — and never carry entity
identifiers, store details or validation reasons. An accepted result carries
the new revision as `current_revision`; a rejection carries the current
committed revision when the coordinator can answer (`None` when unavailable).
`revision_conflict` uses the domain's `actual` revision. These are command
rejections, not protocol failures: the connection remains usable.

`command_id` is correlation only. It is not a durable deduplication key: a
lost result does not undo a commit and there is no automatic retry. When the
connection drops, the client must refresh authoritative state — a fresh
snapshot or cursor replay — instead of blindly resending the mutation.
Ordering is deliberate: the projected event(s) of an accepted commit arrive
before the `command_result` on the same connection. A `durability_uncertain`
rejection answers `accepted=false` even though the mutation may still have
committed; reconciliation has already resolved the durable state, so the
client must refresh rather than assume either outcome. For example, candidate
reconciliation may send `board.task.created` at revision 1 followed by
`accepted=false`, `error="durability_uncertain"`, `current_revision=1`.
A pre-visibility persist failure instead returns `persistence_failed` with the
old revision and emits no Board event. Result delivery overflow sends
`resync_required` and closes the connection; an already durable commit is never
rolled back because its response could not be delivered.

## Task vocabulary

The implementation keeps three task concepts separate:

- **BoardTask / Attempt** — product/business lifecycle. Owned by the
  `domain`/`coordinator` packages, with durable snapshots in `store`.
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
- `runtime`: event history, server lifecycle, platform server/browser seams;
- `domain`: pure Board task/attempt lifecycle, FSM and propose decisions;
- `coordinator`: Fuwaroid single-writer owner of the committed Board state.

Later stages add persistence, domain event delivery and Agent execution without
changing these ownership boundaries.
