///|
/// With the default StopOnFailure policy a cancelled planning attempt still
/// joins its actual Agent, but the joined failure is terminal: the workflow
/// never resumes, admits a wave or plans again, and none of those refusals
/// prompt the UI. Only the explicit continue-on-confirmed-failure policy
/// keeps the paused workflow resumable.
async test "default StopOnFailure joins cancelled planning into a terminal workflow without resume" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group)
    defer ignore(h.board.shutdown())
    let started = h.board.start(title="Cancelled planning").checked()
    h.state.delay = 1000
    let work = group.spawn(() => {
      assert_true(
        h.board.propose(
          parent=started.run.checked().scope[0],
          requirements="planning",
        )
        is Err(_),
      )
    })
    while h.state.active == 0 {
      @async.sleep(1)
    }
    assert_true(h.board.pause())
    work.wait()
    assert_eq(h.state.active, 0)
    let status = h.board.view().checked()
    assert_true(status.paused)
    assert_false(status.stopped)
    assert_true(status.executions.all(e => e.phase == @execution.Settled))
    assert_true(status.snapshot.expansions.is_empty())
    assert_eq(status.snapshot.tasks.length(), 1)
    assert_true(status.to_json().stringify().contains("\"phase\":\"Failed\""))
    let prompts = h.ui.prompts.length()
    assert_eq(h.board.resume_workflow(), Err(@service.NotQuiescent))
    assert_eq(h.board.run_wave(), Err(@service.NotQuiescent))
    assert_eq(
      h.board.propose(
        parent=started.run.checked().scope[0],
        requirements="planning",
      ),
      Err(@service.NotQuiescent),
    )
    assert_eq(h.ui.prompts.length(), prompts)
    let terminal = h.board.view().checked()
    assert_true(terminal.paused)
    assert_true(terminal.to_json().stringify().contains("\"phase\":\"Failed\""))
    assert_eq(terminal.snapshot.tasks.length(), 1)
  })
}
