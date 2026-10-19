///|
struct UnusedFactory {}

///|
impl WorkflowAgentFactory for UnusedFactory with fn prepare(_, _) {
  raise AgentUnavailable
}

///|
/// The latch models a submit whose durable writer has not been proved joined.
/// Even with no Agent active, shutdown must retain exclusive namespace ownership.
async test "uncertain writer prevents journal release after Agent quiescence" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let board = BoardWorkflows(directory~, agents=UnusedFactory::{ }, group~)
    assert_true(board.journal.load() is Ok([]))
    board.uncertain = true
    assert_false(board.shutdown())
    assert_true(board.closed)
    let competing = @journal.FileBoardExecutionStore(directory~)
    assert_true(competing.load() is Err(_))
    competing.close()
    // Test cleanup is explicit only after the simulated uncertainty is resolved.
    // This is not an automatic retry or recovery API exposed to a customer.
    board.uncertain = false
    assert_true(board.shutdown())
    let restarted = @journal.FileBoardExecutionStore(directory~)
    assert_eq(restarted.load(), Ok([]))
    restarted.close()
  })
}
