# S4B: explicit execution orchestration foundation

**S4B is a deterministic, explicitly driven execution orchestrator, not a dynamic
workflow runner.** `colmugx/posoco-ext-board/orchestration` is optional and headless
(native + JS). Nothing is composed automatically by the Board extension, `/board`,
Rabbita, MoonBack, or an observer.

## Architecture and actual integration

```
authoritative Board snapshot
  -> plan_execution (pure)
  -> BoardOrchestrator (trusted host intent / input resolution)
  -> BoardExecutionOwner (exclusive identity journal + structured worker)
  -> PosocoBoardExecutionAdapter (fresh Agent::run_scoped / run_turn)
  -> durable Start / Finish through BoardBackend and Coordinator
```

S4A remains the sole owner of Agent effects, real scope attribution, cancellation
and completion settlement. Its journal format is unchanged. The orchestrator has
only the owner, immutable policy, resolver, and local admission/closed latches:
no task store, execution journal, runtime, command queue, background task or
second Attempt FSM. It reads `owner.board_state()` so planning and execution
cannot accidentally refer to different backends. Domain, backend, persistence,
wire protocol and UI do not depend on orchestration.

Pinned Posoco 0.22.0 still supplies the actual dedicated Agent lifecycle. Generic
Posoco Tasks receipts are not substituted for Agent run/session/turn identity;
there is no new Tasks capability or Supervisor. The caller's TaskGroup owns S4A
workers exactly as before. See [S4A](S4A-execution.md) for the rationale, real API
signatures, gate, outcome mapping and native journal trust boundary.

## Pure planner and eligibility policy

`plan_execution(snapshot, policy, inputs)` is side-effect-free. Inputs are only
Task/Attempt IDs and availability/authorization metadata, not prompts. Output is
an ephemeral `ExecutionPlan` with revision, policy identity, ordered eligible
IDs and blocked rows with structured reasons. It neither mutates its inputs nor
reserves capacity. Output arrays are detached; changing a plan cannot dispatch.

`ExecutionPolicy()` defaults to **disabled**. Opt-in default eligibility is:

- Task stage **Ready** (a detached stage allowlist can be supplied by the host).
- Oldest **Queued Execute** Attempt belonging to that Task.
- Every referenced dependency Task exists and is **Done**.
- Exactly one matching input-availability hint, Available; missing/conflicting
  hints fail closed and Denied takes precedence.

Dependency Done is an **orchestration policy**, not a domain invariant: the
existing domain still allows Ready before dependencies are Done. Done is manually
recordable Board stage completion, not independently verified Agent success.
No automatic dependency-triggered Task move, cancellation or review is added.

Task ordering is priority **Critical > High > Normal > Low**, then creation time
ascending, then Task ID lexicographically (MoonBit UTF-16 String order). Attempt
ordering is creation time ascending, then Attempt ID. Other queued Attempts on
the same Task are not independently dispatched in one call. Blocked dependency
reasons are in sorted ID order. Identical inputs produce identical plans.

The headless facade additionally reports real owner blockers: not attached,
closed, unavailable adapter, active execution, admission in progress, unresolved
journal and historically used Attempt identity. A plan is inspection, not a
promise that these facts remain unchanged.

## Host input, authorization and identities

Implement `BoardExecutionInputResolver`:

- `availability(candidate)` is synchronous metadata inspection only. It must
  not start work, write a journal, allocate execution ownership or reveal input.
- `resolve(candidate)` is cancellable, re-authorizes current explicit host intent,
  and supplies ephemeral input, fresh execution ID, a fresh dedicated session ID,
  and optional positive timeout. It must not start an Agent or other external
  effect. Missing input and authorization denial are explicit results.

Input is not synthesized from Task title/description. Mode is omitted because
S4A supports a single dedicated Agent turn; no unsupported mode is invented.
The host controls session creation, extension factory, credentials and tool
permissions. IDs are subject to S4A validation and durable history uniqueness.
Command IDs and browser capability tokens are not execution authorization or
idempotency guarantees. No input/output is in a plan, status or journal.

## Explicit dispatch and revision boundaries

1. `dispatch_next(planning_revision?)` acquires a synchronous local latch before
   the first await; overlapping calls on this facade return Busy.
2. Read the owner's authoritative Board, plan with current owner facts.
3. An obsolete supplied revision returns `StalePlan(updated_plan)` before input
   resolution. No candidate returns `Blocked(plan)`.
4. Resolve explicit authorization/input for the first deterministic candidate.
5. Re-read and re-plan. Any Board revision change, eligibility loss or change of
   first candidate returns StalePlan. Resolved input/allocated IDs are discarded,
   not journalled or automatically reused. Denial does not silently fall back to
   the next task.
6. S4A rechecks the exact planning revision inside its protected reservation read,
   plus the pure policy guard. No reservation is made if either fails.
7. The owner persists identity, owns the worker and calls the guard again at the
   **actual model gate**, immediately before durable Start. Stage/dependency/input
   hint changes before that gate prohibit provider effects. Unrelated revision
   changes after reservation need not discard an otherwise eligible run; Start
   still uses the live revision and Coordinator optimistic concurrency.
8. Return exactly one S4A handle. Waiting does not dispatch again. Another call
   requires fresh host intent after the owner becomes ready.

Multiple facades do not create slots: the owner's own synchronous latch, active
binding, history and native journal remain authoritative. Use one owner per
Board namespace; never create extra owners to simulate parallelism.

If eligibility changes after reservation but before the gate, reserved identity
can remain Unresolved. That is intentionally conservative, not permission to
replace the ID and try again. After durable Start, dependency or stage changes
do **not** implicitly cancel the run. They are visible in normal Board state.
Explicit cancellation and S4A settlement apply. No Task stage or Review decision
is changed on completion.

## Cancellation and shutdown

`cancel_active(execution_id)` delegates the exact ID to S4A. Wrong-run requests
fail; repeated requests are safe. An acknowledgement is not confirmed termination;
the handle's `wait()` joins and reports settlement/ambiguity.

Cancelling a dispatch during resolution leaves no reservation. Cancelling during
S4A's cancellation-protected reservation is delivered after the facade captures
the exact returned handle. The facade then requests cancellation and joins within
4 seconds. `DispatchCancelled(cleanup_confirmed=false)` means cleanup remains
owned by the host TaskGroup, not that it stopped. It never resends execution.

`shutdown(timeout_ms=4000)` closes orchestration and owner admission, then delegates
owned cancellation/join. An in-flight resolver or reservation causes false until
its caller is joined. Await/cancel that caller and repeat shutdown; release the
native lock and shut down the backend only after true. Resolver implementations
must cooperate with host cancellation. Noncooperative protected work may outlive
a bound, as documented and tested in S4A. Presentation `board.close` is unrelated.

## Recovery, failure windows and security

No new persistent format or repair loop is introduced. S4A's version-1 journal
continues to distinguish Reserved / Running / Finished / Settled / Unresolved.

| Boundary | Behavior |
| --- | --- |
| Planning / input resolution, before reservation | No Agent or identity reservation. Crash cannot trigger replay. |
| Reservation or scope journal write fails/ambiguous | Owner poisoned; no provider effect until confirmed start gate; further dispatch blocked. |
| Task/dependencies changed before gate | No provider effect; reserved history may be Unresolved; manual reconciliation required. |
| Actual execution started / process crashes | Recovered non-Settled identity blocks dispatch. Interrupted normalization is not termination confirmation. |
| Execution completes before Finished/Board Finish | Existing S4A failure windows remain; no automatic retry or replacement execution. |
| Board persistence fails or is uncertain | Committed authoritative events, if any, are preserved. Binding blocks admission; no replay. |
| Final identity settlement write fails | Local outcome is Unresolved even if Board is terminal. |
| Manual Finish races completion | Manual state wins; S4A never overwrites it and blocks further admission. |
| Crash-stale native lock | Store refuses takeover; operator must establish old ownership is dead. |
| Settled history | Cannot reuse execution, Attempt or session ID; no automatic repeat. |

Board and identity journal are separate durable systems; **no exactly-once external
execution claim** is made. Persisted identity history must be retained. Native
files/lock/fsync behavior is unchanged, and existing valid S3 data stays readable.
JS hosts need an injected durable identity store; the memory store is ephemeral.

Status distinguishes configured `policy_enabled` from effective `admission_enabled`
(attached, available, open, non-poisoned and idle owner/dispatcher). Neither flag
reserves a slot or promises a candidate. One owner-status read supplies both the
status facts and plan blockers. Status also exposes actual owner active binding,
current planning revision and candidate counts/reasons through the plan. It contains no prompts, secrets, provider output
or raw exception text. No new telemetry is necessary: S4A's actual scoped started
event and existing authoritative Board events suffice. Selection is never emitted
as execution-started truth.

Trusted headless hosts authorize dispatch; there are no browser controls, HTTP
routes, new wire commands or token-policy changes. Disablement: stop explicit
calls, shutdown and join the owner, retain the journal, then omit orchestration
composition or revert this additive package. Reverting code cannot undo external
side effects or justify deleting an unresolved identity.

## Evidence and limitations

Tests cover pure deterministic eligibility/sorting/copy isolation, resolver denial,
invalid IDs, concurrent facades, stale revisions, cancellation across reservation,
pre-model policy revalidation, dependency changes after start, manual Finish races,
all journal write windows, seeded restart phases and Board persistence uncertainty.
Actual Posoco Agent tests use a deterministic ModelPort for real scope/lifetime,
completion, model failure, timeout and cancellation—not live provider/tool effects.
S3/S4A/native journal/security/web regressions are retained. Process-kill recovery,
provider-specific cancellation and downstream host integration are not claimed.

Deferred: autonomous loops, dynamic workflow graphs, parallel/fan-out execution,
new owners/leases, dynamic task generation, automatic retry/repair, task/review
automation, browser execution authorization, Cetas/SvelteKit/Proton integration.
