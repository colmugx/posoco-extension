///|
struct HeldParallelInput {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
impl @orchestration.BoardExecutionInputResolver for HeldParallelInput with fn availability(
  _self,
  _candidate,
) {
  @orchestration.Available
}

///|
impl @orchestration.BoardExecutionInputResolver for HeldParallelInput with fn resolve(
  self,
  _candidate,
) {
  self.entered.put(())
  self.release.get()
  @orchestration.InputMissing
}

///|
async fn cancel_during_parallel_resolution(deadline~ : Bool) -> Unit {
  @async.with_task_group(group => {
    let backend = parallel_board(group, tasks=["alpha"])
    let owner = @execution.BoardExecutionOwner::with_slots(
      backend~,
      store=@execution.MemoryBoardExecutionStore(),
      adapter_factory=_ => {
        @execution.PosocoBoardExecutionAdapter(extensions=() => [])
      },
      max_concurrency=2,
    ).unwrap()
    assert_true(owner.attach(group) is Ok(_))
    let resolver : HeldParallelInput = {
      entered: @aqueue.Queue(kind=Blocking(1)),
      release: @aqueue.Queue(kind=Blocking(1)),
    }
    let orchestrator = @orchestration.BoardOrchestrator(
      owner~,
      resolver~,
      policy=@orchestration.ExecutionPolicy(enabled=true),
    )
    let runner = @parallel.ParallelWorkflowRunner(orchestrator~, group~)
    assert_true(
      runner.start(
        parallel_spec(
          max_concurrency=2,
          max_elapsed_ms=if deadline { 100 } else { 10000 },
          execution_timeout_ms=if deadline { 50 } else { 1000 },
        ),
      )
      is Ok(_),
    )
    resolver.entered.get()
    if !deadline {
      runner.cancel()
    }
    let status = runner.wait()
    assert_eq(status.phase, @workflow.Stopped)
    assert_eq(
      status.reason,
      Some(
        if deadline {
          @workflow.DeadlineReached
        } else {
          @workflow.CancelRequested
        },
      ),
    )
    assert_eq(status.admitted, 0)
    assert_eq(status.active_count, 0)
    assert_true(owner.bindings().is_empty())
    assert_eq(backend.state().unwrap().attempts[0].status, @domain.Queued)
    assert_true(runner.shutdown())
    backend.shutdown()
  })
}

///|
async test "cancellation during input resolution is stopped not admission failure" {
  cancel_during_parallel_resolution(deadline=false)
}

///|
async test "deadline during input resolution retains its operational stop reason" {
  cancel_during_parallel_resolution(deadline=true)
}
