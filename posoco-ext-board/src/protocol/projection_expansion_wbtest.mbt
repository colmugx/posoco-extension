///|
test "whole graph wire event round trips without decomposing into task events" {
  let proposal = graph_projection_proposal()
  let wire = project_event(proposal.next_state.snapshot(), proposal.events[0])
  assert_eq(
    decode_server_frame(encode_server_frame(Event(wire))),
    Ok(Event(wire)),
  )
}

///|
test "the wire command table still rejects privileged expansion names" {
  for
    name in [
      "board.graph.expand", "board.graph.expansion", "board.expansion.create", "board.task.expand",
    ] {
    let wire : BoardClientCommand = {
      command_id: "c-1",
      name,
      expected_revision: 1L,
      args: {
        "expansion_id": "exp-1",
        "parent": "t1",
        "candidate": Json::object({ "id": "t4", "local_ref": "r" }),
      },
    }
    assert_eq(
      decode_board_command(wire, 1000L),
      Err(
        InvalidCommand(
          command_id="c-1",
          reason="unknown command name '\{name}'",
        ),
      ),
    )
  }
}
