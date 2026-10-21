# Controlled workflow continuation and exact result handoff

This optional trusted-host seam extends `BoardWorkflows`; it is not a new
scheduler, autonomous approval policy, or browser API. Existing manual workflows
are unchanged when no control lease exists. Snapshot schema v2 and execution
journal v1 are unchanged.

## Composition and authority

A host first uses the normal S4E1 graph approval and independent S4E2 scope
approval. At a fully joined, paused runner boundary it may call
`BoardWorkflows::authorize_control(workflow_id~, task_ids~, expected_revision~,
max_runs~, deadline_ms~, authorize~, capture_after_successful_tools~)`.
The live authorization callback defaults to false. This is a separate bounded
execution-session grant: it never commits a graph, extends scope, increases
capacity, changes the original deadline, or replenishes execution counts.

Only distinct canonical tasks mapped by durable same-workflow expansions with
parents in the authorized scope are accepted. The complete existing scope is
frozen and compared at every controlled mutation/admission. Caller arrays are
detached. One live lease is allowed. Model/input/tool/verification policy remains
the trusted host's responsibility; Board owns all execution identities, durable
mutations, planner decisions, admission, actual Agent lifetimes and shutdown.

## Host API

* `control.prepare(task_id~, input~, expected_revision~)` mints canonical
  Attempt/execution/session IDs and calls existing S4E2 preparation. Legal Task
  transitions and queuing are separately durable, not atomic as a group. The
  Attempt ID is retained even if an intermediate operation fails; there is no
  replay/remint route on that lease.
* `control.plan()` calls the existing S4B planner, filtering only the lease's
  prepared, never-attempted exact Task/Attempt candidates. All dependency and
  Task-stage policy remains S4B's.
* `control.run_wave()` takes at most the remaining grant count and original
  concurrency from that planner, dispatches through existing S4D, and joins the
  wave. Admission and model gates check the live callback and exact candidate
  set. Selected candidates are conservatively consumed even on ambiguity; they
  are never blindly re-admitted.
* `control.take_results()` transfers each settled binding once together with
  optional bounded final assistant text. Binding metadata comes from S4A; text
  comes from the exact settled result channel, not global observer order. A
  missing or unusable result does not change an otherwise completed Attempt
  and must never be treated as proof. Results remain inspectable after
  revocation but cannot authorize mutation.
* `control.transition(task_id~, to~, expected_revision~)` is one legal,
  revision-gated durable Task transition. It requires the lease's exact
  consumed successful Execute result, unchanged Task baseline, no other
  Execute or Review Attempt, all dependencies Done, live authority and
  quiescence. Only Running/Review/Done destinations are accepted, subject to
  the existing domain FSM. It does not issue `RecordReview`. Hosts must supply
  their own independent evidence/approval and chain newly returned revisions
  for multi-stage completion. No multi-stage atomicity is claimed.
* `control.revoke()` withdraws new admission/mutation. Releasing the lease only
  occurs once owner quiescence is confirmed. Repeated revocation cannot release
  a newer lease. It does not itself cancel admitted Agents; use existing Board
  Pause/Stop/Cancel controls, which preserve exact ownership and joining.

While a lease is held, ordinary start/propose/graph/scope/prepare/run/move/wait
routes return Busy rather than compete with it or discard its result channels.
Read-only view/preview and existing lifecycle/control operations remain usable.
A pause suspends the host's live callback; explicit in-process resume must
revalidate original authority without resetting the original resource budgets.

## Result capture after tools

`ExecutionCaptureStrategy::ToolFreeFinal` remains the default and planning
contract. Explicitly opted-in `FinalAfterSuccessfulTools` also accepts a bounded
pure-text final Stop completion after zero or entirely successful tool results.
A tool error, tool-call completion, non-text content, oversized output or
unusable identity does not yield a claim. The host cannot change strategy while
an unread result occupies a channel; the service changes it only at a quiescent
lease boundary. Final text is ephemeral and never added to journal v1.

Tool results and final text are claims, not proof. This API provides no verifier,
Decision risk policy, automatic Review approval or implicit Task completion.

## Failure, concurrency and recovery

The coordinator remains the only durable writer. Every mutation uses the
expected revision; unrelated edits may invalidate a pending mutation but never
cause automatic rebasing/retry. Task-version checks prevent obsolete evidence
from authorizing transitions after a Task edit. Each transition is individually
persisted; later failure does not roll it back.

A scoped wave is an optional exact-candidate filter on the existing
orchestrator, not a mutable runner scope replacement. It is installed only with
no active owner bindings and remains guarded through the joined wave. Static
workflows use no filter. Parallel capacity and shared execution/time counters
are unchanged.

On partial preparation, lost responses, durability uncertainty, interrupted or
unresolved ownership: stop and inspect authoritative state and exact bindings.
Never infer replay permission from missing output. Shutdown still joins owned
work and drains accepted persistence before journal-lock release. A failed join
retains ownership.

Control grants, input resolvers, final text and host evidence decisions are
in-process only. Restart preserves graph/Attempt/journal facts, never authority
or automatic execution replay. No stale lock removal, new durable authorization
store, protocol mutation command or migration is introduced. Rollback can keep
the same snapshot and journal codecs; it cannot undo already committed stages.
