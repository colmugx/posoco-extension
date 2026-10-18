# S4E2 — controlled dynamic workflow execution

`dynamic.DynamicWorkflowController` is an optional trusted-headless composition
of S4D execution and S4E1 expansion. It has **no autonomous planning loop**. The
browser Board capability token grants no planning, graph-approval, execution-scope
or workflow authority.

## Separate decisions

1. An owned Agent returns an untrusted, bounded proposal.
2. A trusted host approves the exact S4E1 graph preview.
3. The coordinator durably commits the complete graph and expansion identity.
4. The host separately approves the canonical generated Task IDs for execution.
5. The host explicitly prepares tasks with legal, independently durable commands.
6. Fresh S4B planning and S4D admission may execute exact eligible Attempts under
   the original remaining resource budgets.

Graph approval is not execution authorization. A scope denial leaves the committed
DAG intact. Committed tasks start Created, with no Attempts. Scope approval itself
neither changes a stage nor queues an Attempt. Task text never grants input,
credentials, tool access or further planning permission.

## Workflow authorization

Create the controller with the exclusively dedicated S4A owner, its exact backend,
a trusted `BoardExecutionInputResolver`, host task group and `DynamicWorkflowSpec`.
The constructor verifies backend identity and constructs the sole S4B orchestrator
and S4D runner. It launches nothing until explicit `start()`.

The spec requires a workflow ID, concrete initial scope, maximum executions,
elapsed milliseconds and per-execution timeout. Concurrency defaults to 1 and is
bounded by 8 and the supplied owner's capacity. The execution count ceiling is
1000; elapsed time is at most 24 hours. Invalid values are rejected, not widened.
Initial scope is nonempty, unique, detached and bounded to 200 IDs.

Expansion defaults **disabled** (`expansion=None`). `Some(DynamicExpansionSpec)`
requires maximum expansion reservations (1–16), cumulative generated tasks
(1–200), depth (2–16), and a scope-approval policy. Scope approval defaults
`Denied`; `HostApprover` still requires a separate granting callback on every new
extension. Graph approval always requires the explicit S4E1 approver; there is no
auto-approval policy. S4E1's depth bound applies to both JSON nesting and generated
DAG dependency paths; tightening it below the schema envelope nesting can reject
all proposals. Use 16 unless a tighter shared bound is intentional.

One original start/deadline and execution budget cover original tasks, generated
tasks, planning, approval waits, preparation and host pauses. A planning reservation
conservatively charges **one execution-budget unit before admission**, including
pre-admission rejection. It is not refunded. `runner.admitted` in controlled mode
therefore includes these charged reservations; `settled` counts only confirmed
Settled bindings. Active identities always come from actual owner occupancy.
Expansion attempts similarly consume one bounded reservation even on invalid
output or denial. Committed expansion/task usage is also read from durable S4E1
history, so another proposal cannot reset cumulative graph budgets. No extension
adds executions, concurrency, time or tool permissions.

## Quiescent control boundary

Ordinary S4C/S4D static workflows retain their existing behavior. The optional
`ParallelWorkflowRunner.start_controlled` starts paused and returns to a paused
admission boundary after each fully settled wave, including an empty plan. This
is not an operator pause and does not terminate the workflow.

- `run_wave()` explicitly requests the next fresh S4B/S4D wave.
- `wait_boundary()` waits for the wave to fan in, then refreshes authoritative
  planning/status. `wait()` instead waits for the runner's terminal lifecycle.
- `pause()` withdraws new operations and dispatch, cancels a current proposal or
  preparation operation, and lets an already admitted execution wave settle.
- `resume_workflow()` refreshes state and clears the operator pause **without
  dispatching**. Call `run_wave` separately. Discarded approvals are not restored.

The runner exposes detached `authorized_scope`, `quiescent`, `extend_scope` and
planning-reservation methods only to trusted host compositions. Static starts
cannot use the extension seam. The controller is responsible for proof of durable
lineage and host approval before invoking it. Scope changes require no pending
admission, no active handles/owner slots, no planning reservation and no unresolved
owner. The boundary is rechecked after awaited Board reads. It never occurs inside
an active Agent model gate and never changes pending/active execution identities.
The host must not compose another runner or direct admission authority over this
same owner while the controller's authorization is active.

## Proposals, approval and atomic commit

Reuse S4E1 unchanged: its schema, bounded decoder, shared pure domain DAG validator,
immutable previews, canonical ID allocator, snapshot v2, durable expansion identity,
one `ExpandGraph` transaction and one `GraphExpanded` event/revision increment.
There is no second validator, projection, Agent runtime, journal or scheduler.

The explicit controller sequence is:

```text
prepare_proposal(payload, host authority fields) OR generate_plan(request/channel, authority)
  -> preview()
  -> approve(exact preview, trusted graph approver)
  -> commit(exact approval)
```

Only one proposal/approval operation may be open. Authority IDs are consumed once.
The controller derives parent authority from its current scope; JSON cannot supply
scope or runtime budgets. Each new proposal, including one parented by a generated
task, needs a fresh explicit host authorization call. S4E1 receives a parent-only
workflow-scope proof and separately permitted existing dependencies. Host deadlines
are capped to the remaining workflow deadline. Unknown JSON fields and executable
control fields remain rejected; descriptions remain untrusted data.

Raw host-held proposals can be decoded/previewed while a wave runs, without
cancelling or rewriting that wave. Actual planning and graph commit require the
quiescent boundary. Any intervening revision—including unrelated edits, parent
edits and execution settlement—invalidates the approved revision. No silent rebase
or mutation retry occurs. Reentrant host callbacks cannot pause/cancel and still
leave a usable graph or scope approval behind.

`commit` cancellation retains S4E1's Uncertain host, original mapping/digest and
proposal identity. `reconcile()` is read-only, permitted after pause/cancel, and
never resubmits or reallocates. Matching evidence proves committed; absence stays
frozen and blocks another proposal. Read failures do not discard uncertainty.

## Separate execution-scope approval

Call `authorize_scope_extension(workflow_id, expansion_id, approved_task_ids,
expected_revision, approver)` explicitly after commit/reconciliation. It requires:

- a committed S4E1 record from the fresh authoritative snapshot;
- the same workflow, and its parent in the **previously** authorized scope;
- exactly the complete durable canonical mapping, with no unknown/duplicate IDs;
- matching revision, valid remaining budgets and a quiescent boundary;
- `HostApprover` policy and an explicit per-call Grant on a detached preview.

Only a union is installed: initial scope is never replaced. Identical repeated
approval (regardless of array order) is a no-op, not another authorization/budget.
A different ID set for an already authorized expansion is refused. A child whose
parent has not separately entered scope cannot authorize descendants. Scope grants
are ephemeral in-process facts, not inferred from Board records or browser tokens.

## Generated-task preparation and dependency progression

`prepare_task(task_id, attempt_id, expected_revision)` is an explicit trusted-host
operation only for generated tasks in a separately approved expansion mapping.
The Attempt ID is host-generated; resolver inputs/permissions are independent of
the model's description. The initial path uses ordinary typed Board commands:

1. MoveTask Created → Refining at the supplied revision.
2. MoveTask Refining → Ready at the next revision.
3. QueueAttempt Execute at the next revision, with the supplied unique Attempt ID.

`BoardBackend.submit(BoardCommand)` forwards typed host commands through the same
single-writer coordinator. It adds no wire/browser command name. Each command is
independently durable; these three commands are **not** an atomic graph operation.
Lifecycle/deadline checks occur between steps; accepted commands are joined under
cancellation protection. Revision conflict stops the sequence without blind retry.
Preparation identities/steps stay in process and are never automatically replayed.

Partial preparation retains committed stages. Unknown durability blocks wave
dispatch until `reconcile_preparation(task_id)` reads the exact queued Execute
Attempt back. A partial stage or absent identity remains frozen; the controller
will not regenerate IDs or redo earlier commands. A trusted operator can inspect
and explicitly repair remaining steps through normal domain APIs; reconciliation
only observes the resulting authority, it does not repair it.

S4B still requires **every dependency Task to be Done**. A Succeeded Execute
Attempt does not move its Task to Done (or even change its stage). Completion is
manual/operator-controlled: separately verify evidence and perform legal stage
transitions. S4E2 does not auto-approve Review Attempts or invent completion
policy. Generated B depending on A remains blocked after A's Agent succeeds until
the host independently establishes Done.

## Owned Agent planning

`generate_plan` constructs S4E1 `OwnedAgentPlanSource` using this same S4A owner,
the host-supplied dedicated queued Execute Attempt/request and the private channel
already wired into its adapter. The exact session/run/turn return is consumed only
after Settled + Completed, never inferred from global Observer event ordering.
Planning is reserved at a quiescent boundary and charged to shared count/time
budgets; it cannot overlap another wave or exceed the frozen capacity. The model
gate rechecks live workflow/planning authority. A failed join fails closed.

Use isolated trusted extension factories with no Board mutation tools or implicit
credentials and no prompt/output logger/session store unless separately approved.
The controller creates neither an Agent nor a second owner. Raw prompts/results
never enter the identity journal. S4E1 strictly parses/validates the result before
the host sees an approval preview.

A planning adapter's private channel may also capture ordinary execution output
if the host reuses that adapter for work. After the corresponding settled wave,
the host must consume/discard that non-planning result before reusing the channel,
or provide separate per-slot planning availability. Never share an unscoped
result channel between concurrently running adapters.

Planning Attempt Start/Finish advance Board revision. The model proposal must
name the actual **post-settlement** revision. Concurrent edits reject it; this
slice does not rewrite model output or automatically repeat the planning run.

## Pause, cancellation, shutdown and failure windows

Cancellation stops new admission, cancels exact actual owned runs and joins
through S4A/S4D. Cancelling a command waiter cannot roll back an accepted
coordinator transaction. Graph uncertainty is retained even after cancellation.

`shutdown(timeout_ms)` revokes authority, cancels/joins the operation task, then
requires runner/owner quiescence and no unresolved execution. It finally closes
and **drains BoardBackend last**, including accepted graph transactions whose
waiters were cancelled. Only a true return permits releasing the enclosing task
group/native journal lock. False requires retaining ownership and service scope;
never turn unresolved into success by deleting journal records. Shutdown may be
retried to confirm termination, not to retry any mutation.

| Window | Result / required host action |
| --- | --- |
| Invalid/failed planning or graph denial | No graph mutation; reservations remain charged |
| Revision conflict before graph persistence | No graph mutation; new explicit proposal/approval required |
| Graph visible, acknowledgement lost | Preserve mapping/digest; read-only S4E1 reconciliation |
| Graph committed, scope denied | Created graph retained, outside execution scope |
| Preparation partly persisted | Keep committed stages; inspect/manual repair, no sequence replay |
| Preparation durability uncertain | Freeze admission, reconcile exact Attempt, never blind retry |
| Generated Agent fails | S4A settles only that Attempt; S4D failure policy applies |
| Agent/journal unresolved | No new admissions; shutdown false, retain ownership |
| Shutdown while approval pending | Withdraw approval; no graph/execution effect |

Protected settlement/preparation may exceed the requested cancellation/deadline
while confirming an already accepted effect; they cannot authorize another effect.
Deterministic tests exercise real Posoco Agents, memory-store fault injection and
S4E1's retained native file-store regressions. These are not live-provider network,
real tool-side-effect, process-kill or power-loss guarantees.

## Read-only status

`status()` returns detached metadata: workflow/runner phase, last observed Board
revision, authorized scope, generated/expansion usage, remaining execution/time/
expansion/task budgets, pending proposal ID once previewed, approval/commit phase,
last committed expansion ID, actual active execution bindings, confirmed settlement
counts, preparation-step observations, structured blockers and unresolved state.
It contains no task text, prompts, credentials, raw model output or raw exception
details. Committed, scope-authorized and actually active tasks remain distinct.

`refresh_status()` refreshes Board usage and calls the existing S4B planner;
commit, scope grant and boundary waits use this read path. Controlled S4D also
replans after each settled wave before pausing. Status is an observation, not an
atomic admission reservation: concurrent external edits can immediately stale it,
and usage/plan reads can observe different revisions. Every mutation and actual
admission independently revalidates fresh authoritative state. `wait_boundary`
waits for the controller operation and planning reservation as well as the runner;
a paused runner alone never proves that a planning Agent joined.

## Worked example

With existing parent P, authorize workflow W with scope `[P]`, four executions,
two slots, a fixed elapsed deadline and explicit expansion bounds/policies.

1. The host legally prepares P and queues distinct original-work and planning
   Execute Attempts. `start()` remains at the controlled boundary.
2. `generate_plan` admits only the dedicated planning Attempt through the owned
   Agent/channel. A deterministic ModelPort emits proposal E with A and B→A and
   the post-planning-settlement revision. This consumes execution unit 1.
3. `preview` validates E. A trusted graph approver Grants; `commit` atomically
   persists A/B as Created, no Attempts, one expansion identity/event/revision.
4. A **different** explicit scope approver Grants exactly E's canonical A/B IDs
   at the fresh revision. Scope is now `[P,A,B]`, with no added runtime budget.
5. The host calls `prepare_task` separately for A and B with unique Attempt IDs
   and successive fresh revisions (three durable commands each).
6. `run_wave` freshly plans and executes original P and independent A in two
   slots. `wait_boundary` confirms both settled (units 2 and 3). B is still queued
   and blocked by A not Done. No Review approval or task completion is fabricated.
7. The operator independently verifies A and moves Ready→Running→Review→Done
   using legitimate commands. The next fresh `run_wave` admits B (unit 4).
8. Inspect fresh status: four confirmed settlements, zero execution budget,
   exact owned bindings in journal v1, one graph expansion in snapshot v2. Join
   and drain shutdown before releasing the journal lock.

See `src/dynamic/agent_integration_test.mbt` for this end-to-end actual-Agent
controlled-ModelPort test on native and JS.

## Restart, compatibility and rollback

No workflow authorization is persisted. A process restart neither starts the
controller nor restores scope approval from graph history—even after a previous
process approved scope but had not executed it. A new explicit workflow start
only authorizes its freshly supplied initial scope. Any generated scope still
needs a fresh trusted-host grant. Historical Attempt identities remain owned and
cannot be redispatched. Restart tests recreate components from persisted memory
snapshots/journals; they do not claim process-kill testing.

Snapshot v2, S4E1 identities, journal v1, the eight browser commands and static
S4C/S4D semantics remain compatible. No new dependency or durable workflow store
is introduced. Disabling dynamic composition stops new authorizations; it does not
delete committed graphs, Attempts or external effects. Preserve data and follow
S4E1's restrictions on rolling back to pre-v2 readers: stop writers, use a reviewed
migration or consistent backup, never strip identities merely to permit retry.
No distributed execution, leases, unlimited recursion/concurrency, browser runtime
authority, Cetas or UI-product integration is included.
