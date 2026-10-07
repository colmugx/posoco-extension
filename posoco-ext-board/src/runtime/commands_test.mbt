///|
async test "runtime command facade returns correlation and stable lifecycle rejection" {
  let runtime = @runtime.default_board_runtime(8)
  let wire : @protocol.BoardClientCommand = {
    command_id: "start-1",
    name: "board.attempt.start",
    expected_revision: 0L,
    args: { "id": "attempt-1" },
  }
  assert_eq(runtime.handle_command(wire), {
    command_id: "start-1",
    accepted: false,
    error: Some("board_initializing"),
    current_revision: None,
  })
  assert_eq(runtime.current_seq(), 0L)
  runtime.shutdown()
  assert_eq(runtime.handle_command(wire), {
    command_id: "start-1",
    accepted: false,
    error: Some("board_unavailable"),
    current_revision: None,
  })
}
