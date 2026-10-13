# Bounded parallel workflows

One trusted host authorizes bounded waves; one multi-slot S4A owner retains all
Agent lifetimes and the single journal. No next wave passes an unconfirmed
settlement. Concurrency defaults to one and explicit opt-in is capped at eight.

This checked composition admits no work and invents no execution input:

```mbt check
///|
struct ParallelNoInput {}

///|
impl @orchestration.BoardExecutionInputResolver for ParallelNoInput with fn availability(
  _self,
  _candidate,
) {
  @orchestration.Missing
}

///|
impl @orchestration.BoardExecutionInputResolver for ParallelNoInput with fn resolve(
  _self,
  _candidate,
) {
  @orchestration.InputMissing
}

///|
async test "explicit two-slot host composition without execution input" {
  @async.with_task_group(group => {
    let board = @backend.BoardBackend()
    board.attach(group)
    assert_true(board.bootstrap_snapshot() is Ok(_))
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend=board,
      store=@execution.MemoryBoardExecutionStore(),
      adapter_factory=_ => {
        @execution.PosocoBoardExecutionAdapter(extensions=() => [])
      },
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let orchestrator = @orchestration.BoardOrchestrator(
      owner~,
      resolver=ParallelNoInput::{ },
      policy=@orchestration.ExecutionPolicy(enabled=true),
    )
    let runner = @parallel.ParallelWorkflowRunner(orchestrator~, group~)
    let spec = @parallel.ParallelWorkflowSpec(
      run_id="trusted-host-wave",
      scope=@workflow.AllEligibleAtStart,
      max_concurrency=2,
      max_executions=4,
      max_elapsed_ms=10000,
      execution_timeout_ms=1000,
    )
    assert_true(runner.start(spec) is Ok(_))
    assert_true(runner.pause())
    assert_true(runner.stop_after_wave())
    assert_eq(runner.wait().phase, @workflow.Stopped)
    assert_eq(runner.status().admitted, 0)
    assert_true(runner.shutdown())
    board.shutdown()
  })
}
```

Memory storage is ephemeral/test-only. Durable hosts supply the native identity
store, retain its namespace lock after a false shutdown, and close BoardBackend
last. Dedicate the owner/orchestrator to this runner during a workflow.
See [S4D](../../docs/S4D-parallel-workflow.md) for scope, policies, budgets,
restart limitations, serialized persistence and rollback.
