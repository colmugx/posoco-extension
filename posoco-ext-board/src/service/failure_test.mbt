///|
async test "provider failure is durably settled without exposing raw provider details" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group)
    defer ignore(h.board.shutdown())
    let initial = h.board.start(title="Provider failure").checked()
    h.state.fail = true
    assert_true(
      h.board.propose(
        parent=initial.run.checked().scope[0],
        requirements="planning",
      )
      is Err(_),
    )
    let view = h.board.view().checked()
    assert_eq(view.executions.length(), 1)
    assert_eq(view.executions[0].phase, @execution.Settled)
    assert_eq(view.executions[0].outcome, Some(@execution.Failed))
    assert_true(view.snapshot.expansions.is_empty())
    assert_false(view.to_json().stringify().contains("private-provider-secret"))
  })
}
