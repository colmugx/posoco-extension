# S4A: opt-in owned Agent execution

## Decision and boundary

S4A uses **Option B**, an explicitly injected, trusted-host execution adapter in
`colmugx/posoco-ext-board/execution`. It is not installed by `BoardExtension`,
`BoardBackend`, the browser or the native localhost host. Manual Queue/Start/
Finish remain bookkeeping commands and never launch an Agent.

`BoardExecutionOwner` owns one worker in a host `TaskGroup`. The supplied
`PosocoBoardExecutionAdapter` constructs a fresh, exclusively owned Posoco Agent
per request and runs `Agent::run_scoped` / `Agent::run_turn`. The host supplies
fresh extensions, configuration, readiness and explicit input. No provider,
credentials, tools, authorization policy or execution input is supplied by Board.

The pinned Posoco 0.22.0 Tasks surface was evaluated: `TaskSpec.run` is an arbitrary
closure returning a Message; `TaskHandle.wait/cancel` owns that generic closure,
not an actual Agent run identity. Its receipt is not an Attempt-to-Agent binding.
`CompositionView::tasks()` also requires `Capability::Tasks`. Board adds no such
capability. `AgentControl::abort_active` targets the current active run rather
than accepting a caller's execution identity. This slice instead cancels the
exact task owning a dedicated Agent; it never exposes or aborts a shared host
Agent. It reuses structured async ownership, not a second task runtime/scheduler.

The domain, coordinator and backend do not import this package. Backend adds
only `state()`, a detached coordinator snapshot for trusted headless consumers.
There are no protocol, browser, HTTP, manifest or persistence-format changes.

## Host composition

1. Construct/attach the backend and wait for its authoritative readiness.
2. Create one private execution journal for that Board namespace.
3. Construct an adapter with a **fresh-extension factory** and the host's policy.
4. Construct/attach one owner to the host TaskGroup.
5. Call `execute(BoardExecutionRequest)` only after trusted explicit authorization.
6. Wait on its handle; an Unresolved binding is not a successful settlement.
7. On final host shutdown, stop admission and await `owner.shutdown()` **before**
   backend/runtime shutdown. Release the journal lock only after confirmed join.

`board.close` closes presentation only; it must not call execution shutdown.
A composition regression tests this with a presentation adapter. Existing native
socket teardown tests remain unchanged.

Requests contain Task ID, Attempt ID, execution ID, a fresh dedicated session ID,
explicit ephemeral input, and an optional positive timeout. Host-generated IDs
must be stable and unique within the journal, not derived from command IDs. Inputs
and Agent outputs are never journalled. The actual run/turn IDs come from Posoco's
scoped `TurnStarted`, not from caller guesses or event ordering across sessions.

The factory and custom adapter/store implementations are **trusted**, not a
sandbox. Do not supply shared execution owners or lifecycle extensions that
start unrelated work before the model gate. The Agent scope joins owned managed
tasks, not detached subprocesses or work spawned outside that scope. A host that
cannot guarantee this ownership must leave the adapter unavailable. The supplied
native journal is POSIX-oriented; unsupported filesystem sync behavior fails
closed rather than degrading durability. JS hosts may provide another durable
`BoardExecutionStore`; the memory store is deliberately ephemeral/test-only.

## Admission and correlation

V1 permits **one active execution per owner/Board namespace**. A synchronous
admission latch covers concurrent callers before any await. Backend and adapter
must be ready, the Task must exist, and its Attempt must be **Execute + Queued**.
Task stage is irrelevant to the default S4A policy. Already manually started
Attempts are not adopted. S4B adds optional `reservation_revision` and a trusted
side-effect-free `admission_guard` to `execute`: the revision is checked before
reservation, and the guard receives detached Board state at reservation and again
at the actual model gate before durable Start/provider effects. Defaults preserve
S4A behavior. Guard rejection after reservation may leave an unresolved identity;
see [S4B policy and recovery](S4B-orchestration.md).

The version-1 journal stores only identity, actual scope, phase and outcome:

`Reserved -> Running -> Finished -> Settled`, or `Unresolved`.

Execution, Attempt and session identities cannot be reused even after settlement.
The caller must preserve this journal and use one owner for the namespace.
`execution/native.FileBoardExecutionStore` uses an exclusive lock sentinel,
0600 files, fsync, atomic rename and directory fsync in an existing private host
folder. It never silently reacquires a crash-stale lock. It rejects symlinked
journal/root paths and pre-existing temporary paths; the host must protect the
folder and its ancestors against other writers. This is not a multi-host lease.

The driver installs its scope observer and model gate first. Before a model/tool
can run, the gate must:

1. Persist the actual session/run/turn association.
2. Submit `board.attempt.start` through the durable backend using current revision.
3. Confirm acceptance and persist Running metadata.

Any failure prohibits provider invocation. A queued coroutine alone never marks
an Attempt Running. Only the actual scoped Agent reaching its model gate does.
A metadata-only `execution.started` telemetry event carries explicit execution/
Attempt IDs and actual scope. It contains no prompt, response or tool output.
Unscoped events never establish attribution; telemetry is not durable truth.

## Completion policy

The driver returns only after `run_scoped` cleanup. Completed requires an admitted
scope, matching session and an observed scoped `TurnCompleted`. A returned final
message alone is insufficient. **Completed means the Agent turn completed, not
that its answer proves task correctness**; the explicit v1 mapping is:

| Execution outcome | Durable Attempt outcome |
| --- | --- |
| Completed | Succeeded |
| Failed | Failed |
| Cancelled, after owned cleanup | Cancelled |
| TimedOut / Interrupted | Interrupted |

Task stage and Review decision remain unchanged. The owner persists Finished,
reads the live authoritative Attempt, and makes **one** durable Finish submission.
A manual terminal mutation wins: completion never overwrites it. Conflict,
unavailability, persistence failure or durability uncertainty leaves the binding
Unresolved and locks admission. An uncertain command may already have committed;
its authoritative Board event is preserved and never rolled back or blindly
retried. Duplicate waits do not repeat settlement.

Cancellation acknowledgement only requests cancellation for the exact owned
execution ID. Wrong IDs fail; repeated requests are harmless. The handle confirms
termination/settlement, not the acknowledgement. Cancellation before worker entry
is recorded without launching the driver. During shutdown the default join budget
is 4 seconds. `false` means cleanup is unconfirmed: admission stays closed and the
host TaskGroup retains ownership. Non-cooperative protected cleanup may outlive
the budget; the host must not release the lock or shut down the backend as though
termination were confirmed. A regression explicitly tests this distinction.

## Failure windows and restart

Board persistence and the identity journal are two durable systems, **not one
atomic transaction**. This PR does not claim exactly-once external execution.

| Boundary | Conservative behavior |
| --- | --- |
| Before reservation persists | No Agent starts. A failed/ambiguous write disables further admission. |
| Reserved, before Agent identity | Crash leaves Reserved; restart never replays it. |
| Scope persisted, before durable Start | No model effect until Start and Running metadata both confirm. |
| Start commits but Running journal write fails | No provider call; Attempt may be Running. Binding is unresolved. |
| Running, process crashes | Agent termination is unknown; Board's Interrupted normalization is not proof of termination. |
| Agent terminates, before Finished persists | Running journal remains unresolved on recovery. No execution restart. |
| Finished persists, before Board Finish commits | Actual outcome is retained, but no automatic durable command retry on restart. |
| Board Finish commits, final journal write fails | Board event remains authoritative; local binding reports Unresolved, not durably Settled. |
| Settled | Identity reuse is rejected; no replay. |

All recovered non-Settled phases disable execution admission for the namespace.
V1 deliberately has no automatic repair/replay API. An operator must establish
that the old owner and any external work are dead, inspect Board and journal
state, and reconcile through explicit trusted operations. Do not delete identity
history or remove a stale lock merely to make a retry succeed. Preserve forensic
metadata. A new attempt/execution identity requires explicit fresh user intent.

The journal is separate from S3 `board.json`/`events.jsonl`; valid S3 snapshots
remain readable without migration. Restart compatibility is tested with real
FileBoardStore and the identity journal.

## Security, disablement and evidence

This slice exposes **no browser execution button, WebSocket execution command or
HTTP mutation route**. The localhost capability token continues to authorize only
the existing Board surface. Trusted headless callers own execution authorization
and input policy. To disable execution, stop admission/shut down the owner and
omit adapter composition. Reverting the PR disables the optional API but cannot
undo external effects; retain journal files and resolve active work first.

Tests invoke the **actual pinned Posoco Agent** with a deterministic ModelPort:
real scope identity, gate-before-provider, completion, model failure, timeout,
scoped cancellation and Agent lifecycle shutdown. Native integration also uses
real filesystem Board/journal persistence and restart. Fake adapters inject
concurrency, wrong identities, manual finish races, ambiguous journal writes and
non-cooperative cleanup. These are not claims of live provider-network, real tool
side-effect, Cetas integration or cross-process crash-kill testing. Recovery tests
seed every journal phase and test actual reload/refusal; process-kill recovery
and provider-specific cancellation remain host integration work.

Deferred: authenticated browser execution admission, attaching/adopting shared
Agents, distributed leases, automatic recovery, task-stage automation, review
automation, fan-out, scheduler/workflow graphs, Cetas/SvelteKit/Proton adapters.
