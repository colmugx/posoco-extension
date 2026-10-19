# S4F — the composed Board workflow extension

`service.BoardWorkflows`, re-exported at the module root as `BoardWorkflows`, is
the complete, opt-in Board workflow capability. It composes the S4A execution
owner, S4B planning admission, S4C/S4D bounded waves, S4E1 expansion and S4E2
dynamic control into **one extension instance** so customers never assemble those
packages by hand. It is still not a second Agent runtime: Posoco owns model
calls, tool execution, session state and cancellation. The instance is the sole
durable writer for its directory namespace, and the browser Board capability
token grants no workflow, graph-approval, execution-scope or planning authority.

The capability is **disabled by default** (`BoardWorkflowPolicy.enabled=false`).
Every mutation is a trusted, separately approved UI decision recorded through
the host's `UiPort`; no command accepts executable JSON arguments.

## Minimal Lego composition

A client supplies exactly four parts. Everything else is owned by the instance.

```mbt nocheck
// One fresh Agent composition per planning/execution run. Planning
// compositions must expose no tools; no composition may expose sessions,
// logs, Board mutation tools or this Board extension itself.
impl @board.WorkflowAgentFactory for MyFactory with fn prepare(self, context) {
  { extensions: [fresh_model_extension(context)],
    config: @posoco.agent_config(max_tool_rounds=Some(0)) }
}
```

```mbt nocheck
@async.with_task_group(group => {
  let workflows = @board.BoardWorkflows(
    directory="private/board-data",     // host-owned private directory
    agents=my_factory,                  // &WorkflowAgentFactory above
    group~,                             // the host structured-concurrency scope
    policy=@board.BoardWorkflowPolicy(enabled=true),
  )
  let agent = @posoco.Agent(exts=[ui_extension, workflows], config)
  // Run the host loop here. `workflow` / `board.workflow.*` are now available;
  // lifecycle on_shutdown drains the workflow before the scope ends.
})
```

- `directory~ : String` — one private directory per instance. It holds the Board
  snapshot store (`board.json` v2 + `events.jsonl` audit) and the execution
  identity journal (`executions.json` v1) side by side. One instance, one
  directory: a second instance in the same directory is refused while the first
  holds the lock.
- `agents~ : &WorkflowAgentFactory` — `prepare(context)` receives
  `WorkflowAgentContext { purpose: Planning | Execution, workflow_id, task_id,
  attempt_id, session_id, slot }` and returns a fresh
  `WorkflowAgentComposition { extensions, config }`. The adapter rejects
  compositions whose manifest exposes sessions or logs, planning compositions
  with any tool, the `posoco_ext_board` extension itself, or a physical
  extension/model reference already leased by another slot. The factory is a
  trusted capability boundary: it must allocate fresh mutable backing state,
  not hide shared state behind fresh opaque wrappers. Reference checks are
  defense in depth, not a proof about arbitrary wrapper internals. Raw prompts,
  model output and workflow inputs never enter the identity journal.
- `group~ : @async.TaskGroup[Unit]` — the host scope. All workflow work
  (operations, backend workers, execution owner) is spawned there; nothing
  outlives it.
- a `UiPort` extension — the manifest declares `requires=[Capability::Ui]`;
  `on_compose` captures the UI and fails composition with `EmptyPort` when the
  host did not install one.

Optional constructor seams: `policy?` (defaults below), `now_ms?` (clock; tests
inject fixed values) and `authorize?` (live host permission hook below).

## What the instance owns

Clients provide capabilities, not a second execution owner. The instance
constructs and owns all of the following; hosts never recreate any of them.

| Owned part | Fact |
| --- | --- |
| Board store | `FileBoardStore::at_directory(directory)` backend; snapshots v2, audit journal in the same directory |
| Identity journal + lock | `FileBoardExecutionStore(directory)`; `execution.lock` sentinel acquired before any workflow starts; the extension owns lock lifetime end to end |
| Single writer | exactly one operation at a time (`workflow_operation_active` otherwise); one BoardWorkflows per directory; coordinator commits stay serialized |
| Agent owner | one `BoardExecutionOwner::with_slots` over that journal; durable Attempt settlement and cancellation remain S4A's |
| Controller | one `DynamicWorkflowController` per started workflow; created at `start`, never persisted |
| Result channels | one 65536-char `BoardExecutionResultChannel` per slot; settled results are discarded only when nothing is active |
| Budgets | the policy's execution/time/expansion/task budgets, frozen at `start` and shared by planning, waves, preparation and approval waits |
| Shutdown | one lifecycle barrier; see below |

## Policy and budgets

`BoardWorkflowPolicy` defaults: `enabled=false`, `max_executions=8`,
`max_elapsed_ms=600000`, `execution_timeout_ms=60000`, `max_concurrency=2`,
`max_expansions=2`, `max_generated_tasks=20`, `max_depth=16`,
`continue_on_confirmed_failure=false`. Invalid values are rejected at compose
time, never widened. `DynamicWorkflowSpec` range rules apply (execution ceiling
1000, elapsed at most 24 hours, concurrency clamped to 1–8 and the owner's
capacity, expansions 1–16, generated tasks 1–200, depth at most 16).

`continue_on_confirmed_failure` selects the S4D failure policy: the default
`false` is `StopOnFailure`; `true` opts into `ContinueOnConfirmedFailure`, which
continues only after a failure is durably settled. It never retries an
uncertain effect.

Budgets are shared and never increased by any extension: a planning run charges
one execution unit before admission (not refunded, including rejected
proposals), expansion attempts consume bounded reservations, and `start` freezes
one deadline (`now + max_elapsed_ms`) covering everything, including approval
waits and host pauses. `start` fails with `workflow_budget_exhausted` when the
remaining time is below `execution_timeout_ms`.

## Live host permission hook

`authorize? : () -> Bool = () => true` is a constructor-supplied, host-owned
gate. It is consulted live — never cached — before every gated operation, on
every adapter readiness/admission check, before each composed Agent run, and
again on resume. A `false` answer fails closed with `approval_denied`. Nothing
derives this permission from Board records, graph history or the browser token.

## Commands

The extension registers the selector `board.workflow` (alias `workflow`) plus
these actions, all in category `board` with no params. Every invocation must
pass an empty `args` object — "Board commands accept trusted UI decisions, not
executable JSON arguments". Interactive steps use `UiRequest::Input`,
`Select` and `Confirm`; missing UI, cancellation or a non-Yes confirm fails with
`approval_denied` / `trusted_ui_required`.

| Command | Label / behavior |
| --- | --- |
| `board.workflow.status` | Inspect authoritative status (detached `BoardWorkflowView` JSON) |
| `board.workflow.start` | Start bounded workflow; confirms the exact policy JSON; creates the root Task and controller |
| `board.workflow.propose` | Request Agent DAG proposal; authorizes one planning run for a scope parent; consumes one execution unit + expansion reservation |
| `board.workflow.preview` | Preview the proposed DAG; fails before a proposal exists |
| `board.workflow.graph.approve` | Approve graph commit only — confirms "GRAPH APPROVAL — commit exactly this proposal?" |
| `board.workflow.graph.reject` | Reject graph proposal; the preview becomes nonauthoritative |
| `board.workflow.scope.approve` | Approve execution scope separately for one committed expansion's exact canonical task IDs |
| `board.workflow.scope.reject` | Deny execution scope; the committed graph is retained |
| `board.workflow.prepare` | Prepare task with trusted input; persists legal transitions + a queued Execute Attempt |
| `board.workflow.run` | Run next eligible wave from separately authorized inputs and remaining budgets |
| `board.workflow.wait` | Wait for settled wave (permitted while paused/stopped) |
| `board.workflow.pause` | Pause admission; cancels the current operation; an admitted wave still settles |
| `board.workflow.resume` | Resume without dispatch |
| `board.workflow.stop` | Stop after current wave |
| `board.workflow.cancel` | Cancel actual workflow executions (request; settlement is confirmed by `wait`/`status`) |
| `board.workflow.move` | Operator-controlled Task transition with independently verified evidence |
| `board.workflow.reconcile` | Read-only reconciliation of the graph proposal or one partial preparation; never retries |

## Separate approvals — no automatic completion

Graph approval, execution-scope approval, preparation and wave admission are
four distinct confirmations. A graph commit creates Created tasks with no
Attempts; scope approval is a union grant over exact committed IDs and adds no
budget; preparation is three independently durable Board commands, not an
atomic graph transaction (partial preparation freezes dispatch until read-only
reconciliation); `run` admits only exact eligible Attempts under remaining
budgets.

Success never implies completion. A Succeeded Execute Attempt does not move its
Task's stage; `board.workflow.move` performs one legal stage transition after
the operator independently verifies evidence, and never approves a Review
Attempt or fabricates a decision. Review decisions and attempt outcomes remain
explicit, separate backend commands. There is no autonomous planning loop: each
proposal needs a fresh `propose` authorization, and no extension adds
executions, concurrency, time or tool permissions.

## Failure codes

`invoke` returns `CommandOutcome::Success` with structured JSON — the detached
view for state-changing actions, the graph preview for `propose`/`preview`, and
small acknowledgement objects for `pause`/`stop`/`cancel` — or `Failure` with
one stable code:

| Error | Code |
| --- | --- |
| Disabled | `workflow_disabled` |
| InvalidConfiguration | `invalid_workflow_configuration` |
| MissingUi | `trusted_ui_required` |
| Closed | `workflow_closed` |
| Busy | `workflow_operation_active` |
| NotStarted | `workflow_not_started` |
| ApprovalDenied | `approval_denied` |
| RevisionConflict | `revision_conflict_refresh_required` |
| InvalidProposal | `invalid_proposal` |
| AgentUnavailable | `planning_agent_unavailable` |
| StoreUnavailable | `store_unavailable_inspect_lock_and_storage` |
| DurabilityUncertain | `durability_uncertain_inspect_no_retry` |
| UnresolvedExecution | `execution_unresolved_lock_retained` |
| BudgetExceeded | `workflow_budget_exhausted` |
| NotQuiescent | `workflow_not_quiescent` |
| PreparationBlocked | `task_preparation_blocked` |
| OperationRejected | `workflow_operation_rejected_inspect_status` |

Raw provider, store and filesystem exceptions are never UI data. A durability
uncertainty on a Board mutation stays flagged: gated operations then fail with
`durability_uncertain_inspect_no_retry` while the read-only paths (`status`,
`wait`, `reconcile`) remain available for inspection. Nothing is automatically
retried, rebased or replayed.

## Restart, lock and operator recovery

Durable state is exactly the Board snapshot (v2) + audit journal and the
execution identity journal (v1). Workflow authorization is **not** persisted:
after a restart the Board history is readable through `status`, but there is no
controller (`workflow_not_started`), and scope approvals, execution inputs and
pending previews are never restored — not even when a previous process had
approved scope but not executed it. A new explicit `start` authorizes only its
freshly supplied initial scope. There is no crash-authority restore.

The journal lock is a sentinel file `execution.lock`, created exclusively,
fsynced and followed by a directory fsync before any work is admitted. A
competing client's `start` and even a fresh store `load` fail with
`store_unavailable_inspect_lock_and_storage`. Only the owning store releases
its lock after confirmed execution shutdown; the Node adapter additionally
verifies its random ownership token before unlinking. A stale lock
from a crashed process is **never removed automatically**: an operator must
first prove the old owner is dead, then delete `execution.lock` manually.
Journal records must never be deleted or edited to force progress — non-Settled
records are read-only evidence that keep `start` refused
(`execution_unresolved_lock_retained`) and make `shutdown` return `false`,
retaining the lock. `FileBoardExecutionStore::inspect(directory~)` reads that
evidence without acquiring or removing any lock.

Durability is fail-closed on both supported targets. The Board store persists
through six explicit stages — temp write, temp fsync, audit append, audit
fsync, replace-rename, directory fsync — so the rename is the visibility
boundary: a pre-rename failure leaves the previous board authoritative, while a
directory-fsync failure after the rename returns `DurabilityUncertain` (the new
snapshot may be visible). Inspect and refresh; an error is not proof of
rollback, and no compensating rename is attempted. Journal writes are equally
fsynced and renamed; any journal write failure is `StoreUnavailable` and
poisons that instance — ambiguous writes are never replayed or second-guessed
by the extension.

Platform support is stated narrowly, and nothing is promised for platforms
outside it. Native uses the `moonbitlang/async` fsync/replace-rename APIs; the
audit tail-repair C seam supports macOS/Linux and returns `ENOSYS` on
unsupported platforms, macOS uses ordinary `fsync` (not `F_FULLFSYNC`), and no
Windows durability guarantee is made. The JS target uses Node-compatible
synchronous `node:fs`/`node:path`/`node:crypto` entry points (`fsyncSync`,
`renameSync`, `ftruncateSync`, `randomUUID`); other JS runtimes, including Bun,
are neither claimed nor tested. Network filesystems, power loss and storage
caches are not covered on any target, and shared directories with concurrent
external writers remain unsupported — the Board store has no lock of its own,
so the journal lock plus the one-operation gate are the only serialization.

## Shutdown

`shutdown(timeout_ms?=5000)` is the one lifecycle barrier: it closes admission,
cancels and joins the current operation, quiesces the controller (or shuts down
the owner when none), then closes the journal (releasing the lock only after
confirmed join) and drains the Board backend last. A pending/uncertain graph
commit or uncertain preparation prevents lock release even after all Agents
join: cancellation of a commit waiter is not proof that its persistence worker
has drained. Service-originated single commands are shielded through their
coordinator result; expansion cancellation preserves its identity and fails
closed until explicit read-only reconciliation. `on_shutdown` invokes the
barrier and raises `UnresolvedExecution` on a `false` result. A `false` result — for
example with an unresolved journal — means the lock is retained and the host
must keep the service scope alive; retrying shutdown may confirm termination
but never retries a mutation. Never convert unresolved into success by
deleting journal records.

## What the deterministic tests cover

The service suite runs on native and JS with a scripted `UiPort`, a controlled
in-process `ModelPort` (fixed clock, temporary directories, injected
`BeforeRename`/`AfterRename` journal stages and the store's six injected board
stages, real Posoco Agent composition). They cover the end-to-end
plan → approve → scope → prepare → wave → operator-move path, default denial
with no storage or model effects, denial/cancellation windows, invalid model
output, lock exclusion, restart without restored authority, planning
cancellation, slot isolation, provider failure settlement without leaked
provider details, and unresolved-journal read-only behavior. They involve no
live provider network calls, real tool side effects, process kills or power
loss, and they make no CI or platform-certification claims.

## Out of scope

No autonomous planning loop, browser-derived authority, second execution owner
or runtime, distributed execution, cross-process leases, crash-authority
restore, automatic Review approval or Done transitions, workflow-state
persistence, or Cetas/UI-product integration. Low-level S4 packages remain
optional advanced ports; customers wanting narrower surfaces can compose them
directly as documented in the S4A–S4E2 guides.
