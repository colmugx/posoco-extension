///|
struct WorkflowSettlementJournal {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  mut writes : Int32
}

///|
impl @execution.BoardExecutionStore for WorkflowSettlementJournal with fn load(
  _self,
) {
  Ok([])
}

///|
impl @execution.BoardExecutionStore for WorkflowSettlementJournal with fn persist(
  self,
  _records,
) {
  self.writes += 1
  if self.writes == 4 {
    self.entered.put(())
    self.release.get()
  }
  Ok(())
}

///|
async test "workflow deadline during settlement joins without fabricating cancellation outcome" {
  @async.with_task_group(group => {
    let journal : WorkflowSettlementJournal = {
      entered: @aqueue.Queue(kind=Unbounded),
      release: @aqueue.Queue(kind=Unbounded),
      writes: 0,
    }
    let h = workflow_harness(group, tasks=["alpha", "beta"], store=journal)
    assert_true(
      h.runner.start(
        workflow_spec(max_elapsed_ms=150, execution_timeout_ms=100),
      )
      is Ok(_),
    )
    journal.entered.get()
    // Agent is already Completed; durable settlement remains in protected IO.
    // The workflow must cancel/join ownership, not invent Attempt Cancelled.
    @async.sleep(200)
    assert_eq(h.adapter.runs, 1)
    assert_eq(h.owner.bindings()[0].phase, @execution.Finished)
    journal.release.put(())
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Stopped)
    assert_eq(status.reason, Some(@workflow.DeadlineReached))
    assert_eq(status.succeeded, 1)
    assert_eq(status.cancelled, 0)
    assert_eq(h.owner.bindings()[0].phase, @execution.Settled)
    assert_eq(h.owner.bindings()[0].outcome, Some(@execution.Completed))
    assert_eq(h.adapter.runs, 1)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
async test "deadline withdraws admission during held authorization with no reservation" {
  @async.with_task_group(group => {
    let backend = workflow_board(group, tasks=["alpha"])
    let adapter = scripted_adapter()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=@execution.MemoryBoardExecutionStore(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver : HoldingWorkflowResolver = {
      entered: @aqueue.Queue(kind=Unbounded),
      release: @aqueue.Queue(kind=Unbounded),
    }
    let orchestrator = @orchestration.BoardOrchestrator(
      owner~,
      resolver~,
      policy=@orchestration.ExecutionPolicy(enabled=true),
    )
    let runner = @workflow.SequentialWorkflowRunner(orchestrator~, group~)
    assert_true(
      runner.start(workflow_spec(max_elapsed_ms=150, execution_timeout_ms=100))
      is Ok(_),
    )
    resolver.entered.get()
    let status = runner.wait()
    assert_eq(status.phase, @workflow.Stopped)
    assert_eq(status.reason, Some(@workflow.DeadlineReached))
    assert_true(owner.bindings().is_empty())
    assert_eq(adapter.runs, 0)
    assert_true(runner.shutdown())
    backend.shutdown()
  })
}
