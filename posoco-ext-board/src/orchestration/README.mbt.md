# Explicit headless orchestration

This package is optional and host-controlled. Construct one S4A owner for a Board
namespace, supply a trusted input resolver, and opt in to dispatch. Neither
construction nor `plan()` starts work. Each `dispatch_next()` admits at most one
execution; completion never dispatches the next candidate.

The example deliberately supplies no execution input. It demonstrates composition,
read-only planning/status and shutdown without inventing Agent authorization:

```mbt check
///|
struct NoExecutionInput {}

///|
impl @orchestration.BoardExecutionInputResolver for NoExecutionInput with fn availability(
  _self,
  _candidate,
) {
  @orchestration.Missing
}

///|
impl @orchestration.BoardExecutionInputResolver for NoExecutionInput with fn resolve(
  _self,
  _candidate,
) {
  @orchestration.InputMissing
}

///|
async test "headless orchestration composition does not start execution" {
  @async.with_task_group(group => {
    let board = @backend.BoardBackend()
    board.attach(group)
    assert_true(board.bootstrap_snapshot() is Ok(_))
    let owner = @execution.BoardExecutionOwner(
      backend=board,
      adapter=@execution.PosocoBoardExecutionAdapter(extensions=() => []),
      store=@execution.MemoryBoardExecutionStore(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let orchestrator = @orchestration.BoardOrchestrator(
      owner~,
      resolver=NoExecutionInput::{ },
      policy=@orchestration.ExecutionPolicy(enabled=true),
    )
    let plan = orchestrator.plan().unwrap()
    assert_eq(plan.eligible.length(), 0)
    assert_eq(orchestrator.status().unwrap().plan.revision, plan.revision)
    assert_true(
      orchestrator.dispatch_next(planning_revision=plan.revision)
      is Ok(@orchestration.Blocked(_)),
    )
    assert_true(
      orchestrator.cancel_active("unknown") is Err(@execution.WrongExecution),
    )
    assert_true(owner.bindings().is_empty())
    assert_true(orchestrator.shutdown())
    board.shutdown()
  })
}
```

Use a durable identity journal for durable hosts; memory storage above is
explicitly ephemeral. See [S4B orchestration](../../docs/S4B-orchestration.md) for
policy, authorization, cancellation and recovery requirements.

## Optional dispatch scope, guard and timeout ceiling

`plan`, `status` and `dispatch_next` accept an optional `task_scope :
Array[String]`. It is detached from the caller's array once per call; a present
scope authorizes only its listed Task IDs (an empty scope authorizes nothing),
while an omitted scope plans every Task exactly as S4B did. The pure planner
still sees the full snapshot, so dependencies outside the scope keep gating
scoped tasks, and out-of-scope rows are filtered from `eligible` and `blocked`
before first-candidate selection and stale revalidation.

`dispatch_next` also accepts `admission_guard : () -> Bool` (default true) and
`execution_timeout_ms : Int`. The guard is rechecked before resolution, after
resolution, at the owner's protected reservation and at the actual model gate;
a false result before admission is the safe `AdmissionStopped` error with no
reservation and no effect, and a false result at the model gate prevents
provider effects on the already admitted exact run. A nonpositive ceiling is
the safe `InvalidDispatch` error before any effect; otherwise it caps the
resolver timeout and bounds runs that supply none. `board_state()` returns the
same owner's detached authoritative snapshot for runner start scope validation.
All defaults preserve S4B behavior unchanged.

## Parallel owner capacity (S4D)

`BoardExecutionOwner::with_slots` supplies several drivers; the facade plans
against their live capacity. A plan blocks globally with `ExecutionActive` only
when the owner reports no free slot; a Task whose identity is currently active
is suppressed individually while independent Tasks stay admissible, and
historical Attempt IDs still block as `IdentityAlreadyUsed`. The model gate
revalidates only the pinned candidate and its scope on a fresh snapshot with
the pure planner, so a run's own reserved binding never blocks it.
`status().admission_enabled` additionally requires a free slot; policy,
readiness and the serialized facade/owner gates still apply. A fixed wave selects its
ordered distinct candidates once and pins each one:

```mbt check
///|
test {
  let candidate : @orchestration.ExecutionCandidate = {
    task_id: "task",
    attempt_id: "attempt",
  }
  // Fresh admission per candidate: dispatch_next(task_scope=[candidate.task_id],
  // candidate=candidate) admits exactly this Task/Attempt or returns a fresh
  // StalePlan before any effect.
  assert_eq(candidate.task_id, "task")
}
```

`dispatch_next(candidate?=…, …)` requires that pinned candidate to remain the
first eligible one at planning and again after resolution; a rival Attempt
queued mid-wave can never silently replace it.
