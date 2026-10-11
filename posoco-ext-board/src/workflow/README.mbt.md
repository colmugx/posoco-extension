# Bounded in-process workflows

One trusted host authorization sequences S4B dispatches and waits for S4A
**Settled** bindings. Scope, budgets and execution input authorization are
explicit. No browser capability, workflow persistence or crash auto-resume exists.

This checked example uses an empty Board and never invents execution input:

```mbt check
///|
struct WorkflowNoInput {}

///|
impl @orchestration.BoardExecutionInputResolver for WorkflowNoInput with fn availability(
  _self,
  _candidate,
) {
  @orchestration.Missing
}

///|
impl @orchestration.BoardExecutionInputResolver for WorkflowNoInput with fn resolve(
  _self,
  _candidate,
) {
  @orchestration.InputMissing
}

///|
async test "explicit empty workflow and control lifetime" {
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
      resolver=WorkflowNoInput::{ },
      policy=@orchestration.ExecutionPolicy(enabled=true),
    )
    let runner = @workflow.SequentialWorkflowRunner(orchestrator~, group~)
    let spec : @workflow.WorkflowRunSpec = {
      run_id: "host-workflow-1",
      scope: @workflow.AllEligibleAtStart,
      max_executions: 2,
      max_elapsed_ms: 10000,
      execution_timeout_ms: 1000,
      failure_policy: @workflow.StopOnFailure,
    }
    assert_true(spec.validate())
    assert_eq(runner.status().phase, @workflow.Idle)
    assert_true(runner.start(spec) is Ok(_))
    assert_true(runner.pause())
    assert_true(runner.stop_after_current())
    assert_eq(runner.wait().phase, @workflow.Stopped)
    assert_false(runner.resume_workflow())
    runner.cancel()
    assert_eq(runner.status().admitted, 0)
    assert_true(orchestrator.owner_status().active is None)
    assert_true(runner.shutdown())
    board.shutdown()
  })
}
```

Use the native durable S4A identity store for durable hosts; the memory store is
explicitly ephemeral. A false shutdown must retain the host scope and journal
lock. See [S4C](../../docs/S4C-sequential-runner.md) for frozen task scope,
new-attempt policy, failure windows and deadline/cleanup limits.
