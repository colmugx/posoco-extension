# S4C: bounded sequential workflow runner

**S4C is an in-process, bounded sequential workflow runner. It is not a
crash-resumable distributed workflow engine.** It is optional and headless; no
browser token, Board presentation startup or telemetry event authorizes it.

## Ownership and authorization

```
Trusted host WorkflowRunSpec
  -> SequentialWorkflowRunner (workflow package)
  -> BoardOrchestrator (S4B scoped dispatch + trusted input resolver)
  -> BoardExecutionOwner (S4A journal + exclusive Agent lifetime)
  -> durable BoardCoordinator settlement
```

Construct the runner in the same structured host `TaskGroup[Unit]` lifetime as
the attached execution owner. The runner owns one loop task, a structured deadline
timer and a one-item coalescing control queue. It never launches an Agent, writes
an execution/workflow journal or keeps a second Board projection. The existing
S4A owner is the sole external-effects owner. A fresh successful `start(spec)` is
one explicit host authorization; duplicate concurrent starts and reused
in-process workflow IDs are rejected.

The host must supply identity, scope and all budgets. The `WorkflowRunSpec(...)`
constructor defaults to `StopOnFailure`; continuing after confirmed failure
requires an explicit policy:

- Nonblank run identity (at most 256 characters).
- `Selected(task_ids)` or explicit `AllEligibleAtStart`.
- `max_executions`: 1–1000 admissions.
- `max_elapsed_ms`: 1–86,400,000 milliseconds, including pauses and resolution.
- `execution_timeout_ms`: positive and no larger than the elapsed budget.
- `StopOnFailure` (recommended conservative default) or
  `ContinueOnConfirmedFailure`.

There are no implicit unlimited budgets. Leave time for authorization and
settlement rather than setting the entire elapsed budget equal to one execution
ceiling. Every execution is separately authorized by the **existing S4B resolver**;
workflow authorization does not override later denial. Prompts, credentials and
model/tool outputs are absent from run specs, progress and journals.

## Scope, planning and admissions

At start, selected IDs are checked against the authoritative snapshot, copied
and deduplicated. Unknown IDs fail before any dispatch. `AllEligibleAtStart`
freezes **all task IDs present at start**, not just the initially eligible tasks.
Tasks created afterwards cannot enter this workflow. New queued Execute Attempts
on a frozen/selected task may be admitted after fresh authorization and within
the unchanged budgets. External dependency tasks are inspected but never admitted
unless themselves in scope.

S4B receives the full Board snapshot for dependency policy (dependencies must
be Board-stage Done); its eligible/blocked rows are then scope-filtered **before**
selection and fresh revision checks. Deterministic order remains higher priority,
earlier creation time, then the existing String ID comparator; queued Attempts
are ordered by creation time then ID. Done is not proof of Agent success.

Each iteration reads fresh scoped S4B status and dispatches at most one candidate.
The caller guard is checked before and after resolver work, at protected identity
reservation, and at the actual scoped model gate. The execution timeout ceiling
caps the resolver's timeout (or supplies one if absent). S4A retains its independent
live eligibility checks and durable identity reservation.

Only a handle whose joined binding is **Settled** allows another iteration.
Finished, Unresolved, missing outcomes and failed joins stop as Unresolved.
No cached plan drives the next execution. A pre-reservation stale plan may be
recomputed with new host authorization, at most eight consecutive times; this is
not execution replay. Once admitted, an Attempt is never retried by this loop.

No eligible work ends the workflow; it does not poll, await speculative future
tasks or restart itself on Board events. Stage/dependency blocks may be skipped
by planning. A missing/denied input hint anywhere in the scoped blocked rows stops
the workflow conservatively, rather than silently substituting another task.
Resolver rejection also stops; the failure policy only permits continuing after
**confirmed, durably settled execution failure**, not authorization failures.

## Control lifecycle

```
Idle -> Running -> Completed / Failed / Unresolved
          |   |
          |   +-> Stopping -> Stopped
          +-> Pausing -> Paused -> resume_workflow() -> Running
```

- `pause()` withdraws new admission. An already admitted run may finish and
  settle; only then is Paused quiescent. A pause during cancellable resolution is
  checked before reservation. It does not freeze an Agent coroutine.
- `resume_workflow()` only resumes this paused in-process run. It does not reset
  counters or elapsed time and rechecks latest Board, owner and authorization.
- `stop_after_current()` stops after the current settlement without cancelling
  it; while paused or before admission it stops without admitting work.
- `cancel()` requests cancellation of the exact owned handle and stops the loop.
  It is idempotent. A request is not termination proof.
- `wait()` returns progress after the loop's cleanup attempt; Unresolved does
  **not** authorize another workflow or lock release.

Task/dependency changes after admission do not implicitly cancel an execution.
No automatic Task movement, Review decision or inferred completion is introduced.

## Budgets, deadline and failures

Before every admission, enough elapsed budget must remain for the configured
execution timeout. Time consumed by resolver work is checked again before
reservation. Admission counts do not reset on pause/resume. A nonincreasing wall
clock cannot replenish elapsed budget: measurements are clamped to the greatest
observed elapsed value. A separate structured duration timer bounds the entire
loop even during pauses or a wall-clock rollback. It withdraws the admission
guard before delivering deadline cancellation.

The per-execution timeout belongs to S4A and yields its actual TimedOut outcome
(Attempt Interrupted under S4A policy). A workflow deadline instead stops
admission, cancels exact owned execution, then joins/settles. These are distinct
from user cancellation and host shutdown. Confirmed Cancelled stops even under
ContinueOnConfirmedFailure. Failed/TimedOut/Interrupted may continue only after
Settled under that explicit policy. There is no automatic failed-Attempt retry.

Cancellation/deadline cleanup uses a fixed four-second join attempt, matching
S4B's dispatch cancellation bound. Structured cancellation cannot forcibly kill
noncooperative protected IO or a misbehaving adapter: an unconfirmed join leaves
Unresolved and retains the host's lifetime ownership. A deadline is a bound on
admission/run cancellation intent, **not permission to abandon cleanup**.

## Progress

`status()` returns detached metadata: identity/phase, admitted and confirmed
success/failure/cancellation counts, remaining count/time, start/elapsed time,
current Task/Attempt/execution IDs, last observed authoritative Board revision
and typed stop reason. No subscriber queue or unbounded event history is added.
The Board can change after that observed revision; progress is not a new Board
projection. Terminal progress freezes elapsed time at the stop decision.

## Shutdown, restart and failure windows

Host shutdown order is mandatory:

1. Runner withdraws admission and cancels/joins its loop.
2. Runner delegates S4B shutdown and S4A confirmed owned join.
3. Only a **true** shutdown result allows native journal lock release.
4. Shut down BoardBackend last.

False includes in-flight startup, dispatch or noncooperative cleanup. Retain the
host scope and lock and repeat shutdown after confirmed cleanup; do not report
success or manually delete the lock. An unresolved **joined** execution can leave
a durable blocking journal record even when lifetime shutdown is confirmed.
Presentation `board.close` still closes only the UI server.

There is no workflow persistence or restart/resume endpoint. After a process
crash, workflow authorization disappears. Recovered S4A Reserved/Running/Finished/
Unresolved records continue blocking admission, even on an empty Board. Startup
Attempt Interrupted normalization is not proof an external Agent stopped. Fresh
workflow intent cannot bypass the journal, reuse historical settled identities or
replay an uncertain execution. The S3 Board persistence format is unchanged.

A crash before reservation leaves no execution identity; after reservation, after
Agent completion or before settlement retains S4A's fail-closed ambiguity policy.
There is no exactly-once or cross-system-atomicity claim. Operator reconciliation
of ambiguous effects and stale native locks remains outside this runner.

## Validation and limits

Tests exercise pure scope/admission extensions; bounded lifecycle, budgets,
concurrency, recovery and replanning; and actual exclusively owned Posoco Agents
with deterministic ModelPorts. Those Agents have real scoped lifecycle/cleanup,
not live provider/network or arbitrary tool evidence. Existing S3/S4A/S4B and
native journal/security tests remain required.

No browser workflow API, Cetas/SvelteKit/Proton integration, parallel workers,
multiple execution owners, dynamic task generation, graph rewriting or autonomous
unbounded scheduling is implemented. Rollback/disablement: stop admission, confirm
owned shutdown before releasing storage, then remove runner composition or revert
the optional package. Reverting code cannot undo external Agent effects.
