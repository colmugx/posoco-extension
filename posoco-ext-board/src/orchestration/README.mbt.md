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
