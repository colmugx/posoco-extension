# S4D — bounded parallel workflows

S4D is an opt-in, in-process, single-host runner for independent Board executions.
It is not a distributed workflow engine, an Agent-generated planner, or an
exactly-once external-effects protocol. S4C remains available unchanged.

## Ownership and compatibility

A trusted host constructs **one** `BoardExecutionOwner::with_slots` for a Board
namespace, passing one execution store, a fresh isolated adapter factory and an
explicit capacity from 1 through 8. The default is one. The original owner
constructor remains single-slot. The factory runs once per slot; each driver
must exclusively own its Agent lifetime. `PosocoBoardExecutionAdapter` creates a
fresh Agent and calls the host's fresh-extension factory for each run. The host
must not return shared Agents, sessions, mutable execution extensions or drivers.

All slots share the existing S4A binding history and one owner mutex. Reservation,
correlation/model gate plus durable Attempt Start, and terminal journal writes
plus durable Attempt Finish are serialized. Agents themselves run outside that
mutex. Consequently one slow journal write backpressures all admissions and
settlement, rather than allowing concurrent whole-journal replacements to lose a
binding. Concurrent owner admission calls cannot independently write the journal.

The version-1 codec already accepts multiple unique bindings. No persistence
format or schema version changes are needed. Existing S3 Board snapshots and
S4A/S4B/S4C journals remain readable. The native store's exclusive namespace lock,
atomic replacement and fsync behavior are unchanged. Multiple owners/processes
against one journal are unsupported; a stale lock is never removed automatically.

The owner enforces unique Attempt, execution and session identities across its
entire history, and disallows concurrent executions on the same Task. Journal
write errors poison the entire namespace. An unresolved slot cannot authorize
another admission, even if its driver has already terminated.

## Host authorization and scope

`ParallelWorkflowRunner` receives the same orchestrator and structured host
TaskGroup as the owner. Dedicate that orchestrator/owner exclusively to this
runner while its authorization is active; do not concurrently run S4C, direct
owner admissions or another runner against it. The owner still enforces the
absolute capacity and unique identities if a host violates this composition rule.

`ParallelWorkflowSpec` requires a fresh workflow ID, Task scope, maximum admission
count, maximum elapsed duration and per-execution timeout. Concurrency defaults
to one and cannot exceed the owner's capacity or 8. Count is limited to 1–1000,
duration to 1–86400000 ms, timeout to a positive value no greater than duration.
Invalid specifications produce no admission or identity write.

Selected Task IDs are detached, deduplicated and checked at start. All-eligible
mode freezes the Task IDs present at start. Later-created Tasks cannot join.
New queued Execute Attempts on an authorized Task may join a later wave, subject
to the same remaining budgets, historical identity checks and fresh resolver
approval. Dependencies outside scope are inspected but never implicitly executed.

The S4B resolver re-authorizes every candidate and supplies explicit ephemeral
input and fresh execution/session IDs. Availability hints are not authorization.
Missing/denied input stops instead of silently selecting a fallback. No prompts,
credentials or outputs are stored in progress or the journal. The standalone
browser capability token grants no execution permission; no HTTP or UI execution
surface is added.

## Fan-out, dependencies and deterministic ordering

Each iteration reads a fresh authoritative snapshot through S4B. Its existing
pure planner orders Tasks by descending priority, ascending creation timestamp,
then Task ID; Attempts use creation timestamp then ID. At most the remaining
count budget and configured concurrency are selected for a wave. Only one
candidate per Task is selected. Lower available slot indices are assigned first.

Admission is serialized in that deterministic order, not ranked by completion
speed. Before each reservation S4B resolves input, rechecks current revision,
scope, exact candidate and dependency eligibility. A rival Attempt cannot be
substituted silently. Reservation and the actual model gate recheck the runner's
admission guard. A sibling's durable Start can stale a later wave member's
revision. A still-eligible pinned candidate is re-authorized with fresh identities
before reservation, with at most eight consecutive stale results; identities from
failed pre-admission resolutions are discarded. This is not execution replay.
The admitted handle is handed to the runner synchronously before the dispatch
cancellation checkpoint, so every reserved run is counted and retained for cleanup.
There is no worker or unbounded queue per candidate.

Dependency policy remains **all dependency Tasks must be Done**. This is S4B
orchestration policy, not a domain FSM invariant or proof of Agent success. An
Agent's Completed outcome does not move its Task to Done. No Task or Review
transition is automated. Eligibility is revalidated at the model gate before
provider effects. After that gate admits actual execution, dependency changes do
not implicitly cancel the owned run; later admissions recheck them. Strict priority is intentional;
there is no aging/ranking scheduler. Bounded authorization limits its reach.

## Fan-in and failure containment

Every admitted handle has one structured completion waiter. At most eight
completion signals can be queued, with blocking backpressure and no silent loss.
A new wave is planned only after **every** admitted member has terminated and its
binding is `Settled`. `Finished`, callbacks and cancellation acknowledgements do
not satisfy this barrier. Actual completion order may differ from admission order.

The three policies are:

- **StopOnFailure** (default): withdraw further admissions when a confirmed
  unsuccessful result arrives; let already-admitted runs settle, then stop.
- **ContinueOnConfirmedFailure**: after all wave members durably settle, replan
  authorized remaining work. Never retry the failed Attempt.
- **CancelRemainingOnFailure**: withdraw admission and request exact-identity
  cancellation of remaining admitted runs, then join the wave. Cancellation
  before a model gate may conservatively leave an unresolved reserved identity.

Any unconfirmed or unresolved outcome overrides all policies: stop admission,
cancel unrelated active siblings by their own identities, join within the cleanup
policy and report Unresolved. One result never updates another binding. Only the
S4A owner submits durable Attempt Start/Finish through BoardBackend/Coordinator.
Manual finish races or external revision conflicts may make settlement unresolved;
there is no blind retry or direct snapshot mutation.

## Control and budgets

- `start`: one trusted authorization and one host-owned control task. Duplicate
  concurrent starts and reused in-process workflow IDs are rejected.
- `pause`: withdraw new admission; reserved/running members settle first. Paused
  means the wave is quiescent, not that Agents are frozen.
- `resume_workflow`: resume only that in-process paused authorization, with fresh
  planning and unchanged budgets.
- `stop_after_wave`: no new admission, no implicit cancellation of admitted work.
- `cancel`: withdraw admission, cancel exact occupied identities (including a
  reservation whose handle is still being delivered), then join.
- `wait`: await the control task's cleanup attempt. Unresolved is not successful
  shutdown or permission to release a namespace lock.

Count, concurrency and elapsed budgets are checked before dispatch and at
reservation. Once durably admitted, count/pause/stop-after-wave cannot retroactively
invalidate its model gate. Cancellation, deadline and namespace poisoning still
withdraw it. A new execution requires enough remaining duration for its full
configured timeout. S4B caps any resolver timeout to that ceiling.

The elapsed budget starts after successful initial scope validation. It includes
pauses and resolver/settlement time and cannot be replenished by clock rollback.
An independent structured timer expires the workflow, withdraws admission before
cancellation crosses protected I/O, and initiates exact-run cancellation/join.
An execution timeout is S4A's actual TimedOut outcome, not a synthetic workflow
state patch. Neither timeout permits abandoning an Agent.

## Status, shutdown and recovery

Status is detached, read-only metadata: identity, phase, configured concurrency,
occupied bindings, available slots, admission/settlement/outcome counts, remaining
budgets, last observed revision and structured blocked reasons. Active rows are
owner facts, not inferred Task stages. Revision may already have advanced again.
There are no raw provider exceptions, prompts or model/tool outputs.

Final host shutdown order is:

1. Stop runner admission and cancel/join the control task and owned runs.
2. Shut down the orchestrator and owner; join every slot.
3. Only after confirmed join release the execution journal lock.
4. Shut down BoardBackend last.

Runner cleanup uses one shared 4-second join budget; explicit shutdown accepts a
host budget. A false shutdown result retains the enclosing TaskGroup and journal
lock and permits a later repeated shutdown. Cancellation-shielded persistence
may defer timer delivery; noncooperative I/O cannot be forcibly terminated safely.
The structured host scope remains the ultimate lifetime owner. `board.close`
only closes presentation and does not stop these headless executions.

Restart never restores workflow authorization or replays a binding. Any recovered
Reserved, Running, Finished or Unresolved binding blocks the whole namespace,
even alongside settled history. Board startup Interrupted normalization is not
proof an Agent terminated. Historical settled identities remain unusable. An
operator must reconcile external effects before any new admission; no automatic
journal repair, distributed leases or fencing are provided.

## Validation and rollback

Deterministic tests cover bounded fan-out/fan-in, scope, dependencies, cancellation,
serialization, journal ambiguity and recovery. Real Posoco Agents with controlled
ModelPorts verify overlapping, independently scoped lifetimes; they are not
claims of live provider-network or tool-side-effect execution.

Disable admission by stopping the runner/host authorization. Cancel/join and keep
the namespace lock until termination is confirmed. Code rollback is possible
without a data migration because journal v1 is unchanged, but it cannot undo
already-performed Agent side effects. Preserve unresolved records when rolling
back; never delete a journal or remove a stale lock merely to regain capacity.

Deferred: distributed execution, fan-out across processes, Agent-generated task
plans, dynamic DAG rewriting, automatic Task/Review transitions, browser execution
controls, Cetas/SvelteKit/Proton integration, and exactly-once external effects.
