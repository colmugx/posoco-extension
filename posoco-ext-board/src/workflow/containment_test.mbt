///|
struct HoldingWorkflowResolver {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
impl @orchestration.BoardExecutionInputResolver for HoldingWorkflowResolver with fn availability(
  _self,
  _candidate,
) {
  @orchestration.Available
}

///|
impl @orchestration.BoardExecutionInputResolver for HoldingWorkflowResolver with fn resolve(
  self,
  _candidate,
) {
  self.entered.put(())
  self.release.get()
  @orchestration.Authorized({
    execution_id: "held-exec",
    session_id: "held-session",
    input: "explicit input",
    timeout_ms: None,
  })
}

///|
async test "shutdown during cancellable resolution joins without hidden admission" {
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
    assert_true(runner.start(workflow_spec()) is Ok(_))
    resolver.entered.get()
    assert_true(runner.shutdown())
    assert_eq(runner.status().phase, @workflow.Stopped)
    assert_eq(runner.status().reason, Some(@workflow.HostShutdown))
    assert_eq(adapter.runs, 0)
    assert_true(owner.bindings().is_empty())
    backend.shutdown()
  })
}

///|
async test "cancel before worker entry cannot strand the runner in Stopping" {
  @async.with_task_group(group => {
    let h = workflow_harness(group, tasks=["alpha"])
    assert_true(h.runner.start(workflow_spec()) is Ok(_))
    h.runner.cancel()
    h.runner.cancel()
    assert_eq(h.runner.wait().phase, @workflow.Stopped)
    assert_eq(h.adapter.runs, 0)
    assert_true(h.owner.bindings().is_empty())
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
struct HoldingWorkflowJournal {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  mut writes : Int
}

///|
impl @execution.BoardExecutionStore for HoldingWorkflowJournal with fn load(
  _self,
) {
  Ok([])
}

///|
impl @execution.BoardExecutionStore for HoldingWorkflowJournal with fn persist(
  self,
  _records,
) {
  self.writes += 1
  if self.writes == 1 {
    self.entered.put(())
    self.release.get()
  }
  Ok(())
}

///|
async test "unconfirmed reservation IO prevents successful shutdown or further admission" {
  @async.with_task_group(group => {
    let journal : HoldingWorkflowJournal = {
      entered: @aqueue.Queue(kind=Unbounded),
      release: @aqueue.Queue(kind=Unbounded),
      writes: 0,
    }
    let h = workflow_harness(group, tasks=["alpha"], store=journal)
    assert_true(h.runner.start(workflow_spec()) is Ok(_))
    journal.entered.get()
    assert_false(h.runner.shutdown(timeout_ms=10))
    assert_true(h.owner.status().admission_busy)
    assert_eq(h.adapter.runs, 0)
    assert_true(
      h.runner.start(workflow_spec(run_id="forbidden")) is Err(@workflow.Closed),
    )
    journal.release.put(())
    let status = h.runner.wait()
    assert_eq(status.phase, @workflow.Unresolved)
    assert_true(h.owner.status().unresolved)
    assert_eq(h.adapter.runs, 0)
    assert_true(h.runner.shutdown())
    h.backend.shutdown()
  })
}

///|
struct GatePausedWorkflowAdapter {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  mut effects : Int
}

///|
impl @execution.BoardExecutionAdapter for GatePausedWorkflowAdapter with fn ready(
  _self,
) {
  true
}

///|
impl @execution.BoardExecutionAdapter for GatePausedWorkflowAdapter with fn run(
  self,
  request,
  gate,
) {
  self.entered.put(())
  self.release.get()
  if !gate({
      session_id: request.session_id,
      run_id: "gate-run",
      turn_id: "gate-turn",
    }) {
    return @execution.Failed
  }
  self.effects += 1
  @execution.Completed
}

///|
async test "pause after admission but before model gate allows the admitted run to settle" {
  @async.with_task_group(group => {
    let backend = workflow_board(group, tasks=["alpha"])
    let adapter : GatePausedWorkflowAdapter = {
      entered: @aqueue.Queue(kind=Unbounded),
      release: @aqueue.Queue(kind=Unbounded),
      effects: 0,
    }
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=@execution.MemoryBoardExecutionStore(),
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = scripted_resolver(available=["alpha/attempt-alpha-1"])
    let orchestrator = @orchestration.BoardOrchestrator(
      owner~,
      resolver~,
      policy=@orchestration.ExecutionPolicy(enabled=true),
    )
    let runner = @workflow.SequentialWorkflowRunner(orchestrator~, group~)
    assert_true(runner.start(workflow_spec()) is Ok(_))
    adapter.entered.get()
    workflow_yield_until(what="delivered admission", check=() => {
      runner.status().admitted == 1
    })
    assert_true(runner.pause())
    assert_eq(runner.status().phase, @workflow.Pausing)
    adapter.release.put(())
    workflow_yield_until(what="quiescent pause", check=() => {
      runner.status().phase == @workflow.Paused
    })
    assert_eq(adapter.effects, 1)
    assert_eq(owner.bindings()[0].phase, @execution.Settled)
    assert_true(runner.stop_after_current())
    assert_eq(runner.wait().phase, @workflow.Stopped)
    assert_true(runner.shutdown())
    backend.shutdown()
  })
}
