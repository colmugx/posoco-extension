///|
async test "controlled admission keeps detached task versions through fresh planning" {
  @async.with_task_group(group => {
    let backend = orch_board(group)
    let adapter = orch_adapter()
    let journal = orch_journal()
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter~,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    let resolver = orch_resolver()
    let scheduler = orch_facade(owner, resolver)
    let state = owner.board_state().unwrap()
    let candidates = scheduler.plan().unwrap().eligible.copy()
    let versions = state.tasks.copy()
    assert_true(
      scheduler.set_control_scope(Some(candidates), task_versions=versions, authorize=() => {
        true
      }),
    )
    candidates.clear()
    versions.clear()
    assert_eq(scheduler.plan().unwrap().eligible.length(), 1)
    // Still Ready and ordinarily eligible, but no longer the task version
    // approved with the trusted input. A fresh planner must not bless it.
    orch_command(backend, "board.task.update", {
      "id": "task",
      "title": "externally changed objective",
    })
    assert_true(scheduler.plan().unwrap().eligible.is_empty())
    assert_eq(journal.writes, 0)
    assert_eq(adapter.calls, 0)
    assert_true(scheduler.set_control_scope(None, authorize=() => true))
    assert_eq(scheduler.plan().unwrap().eligible.length(), 1)
    assert_true(scheduler.shutdown())
    backend.shutdown()
  })
}
