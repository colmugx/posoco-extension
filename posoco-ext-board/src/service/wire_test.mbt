///|
async test "wire snapshot and command share the workflow backend" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group, max_executions=1)
    defer ignore(h.board.shutdown())
    h.board.wire_ready().checked()

    let before = match
      @protocol.decode_server_frame(h.board.wire_snapshot().checked()) {
      Ok(@protocol.Snapshot(snapshot)) => snapshot
      _ => fail("expected an authoritative snapshot")
    }
    assert_eq(before.board_revision, 0L)

    let args : Json = {
      "id": "task-wire-1",
      "title": "Wire task",
      "description": "",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
    }
    let command = @protocol.encode_client_frame(
      @protocol.Command({
        command_id: "cmd-wire-1",
        name: "board.task.create",
        expected_revision: 0L,
        args,
      }),
    )
    let result = match
      @protocol.decode_server_frame(h.board.wire_command(command).checked()) {
      Ok(@protocol.CommandResult(result)) => result
      _ => fail("expected a correlated command result")
    }
    assert_true(result.accepted)
    assert_eq(result.current_revision, Some(1L))

    let after = match
      @protocol.decode_server_frame(h.board.wire_snapshot().checked()) {
      Ok(@protocol.Snapshot(snapshot)) => snapshot
      _ => fail("expected a post-command snapshot")
    }
    assert_eq(after.board_revision, 1L)
    let board = match after.payload {
      Object(fields) =>
        match fields.get("board") {
          Some(Object(board)) => board
          _ => fail("snapshot has no board object")
        }
      _ => fail("snapshot payload is not an object")
    }
    let tasks = match board.get("tasks") {
      Some(Array(tasks)) => tasks
      _ => fail("snapshot has no task array")
    }
    assert_eq(tasks.length(), 1)
  })
}
