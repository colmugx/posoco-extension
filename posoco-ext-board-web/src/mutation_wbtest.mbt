///|
test "create command schema carries every editor field" {
  let editor : Editor = {
    mode: CreateMode,
    title: "  Ship it  ",
    description: "Body",
    priority: High,
    definition_of_done: "Tests pass\n\n  Review clean \n",
  }
  let command = create_command("uuid-1", 7L, editor)
  assert_eq(command.command_id, "cmd-uuid-1")
  assert_eq(command.name, "board.task.create")
  assert_eq(command.expected_revision, 7L)
  assert_eq(command.args, {
    "id": "task-uuid-1",
    "title": "Ship it",
    "description": "Body",
    "priority": "high",
    "definition_of_done": ["Tests pass", "Review clean"],
    "dependencies": [],
  })
}

///|
test "update command schema targets the edited task" {
  let editor : Editor = {
    mode: EditMode(task_id="task-9"),
    title: "Renamed",
    description: "",
    priority: Low,
    definition_of_done: "",
  }
  let command = update_command("uuid-2", 3L, "task-9", editor)
  assert_eq(command.command_id, "cmd-uuid-2")
  assert_eq(command.name, "board.task.update")
  assert_eq(command.expected_revision, 3L)
  assert_eq(command.args, {
    "id": "task-9",
    "title": "Renamed",
    "description": "",
    "priority": "low",
    "definition_of_done": [],
  })
}

///|
test "move command schema rides the client enum wire spelling" {
  let command = move_command("uuid-3", 4L, "task-9", Review)
  assert_eq(command.command_id, "cmd-uuid-3")
  assert_eq(command.name, "board.task.move")
  assert_eq(command.expected_revision, 4L)
  assert_eq(command.args, { "id": "task-9", "to": "review" })
}

///|
test "command payloads encode correlated Command frames and Hello stays separate" {
  let command = move_command("uuid-4", 0L, "t", Created)
  match @protocol.decode_client_frame(command_payload(command)) {
    Ok(Command(decoded)) => assert_eq(decoded, command)
    _ => fail("expected Command frame")
  }
  match
    @protocol.decode_client_frame(hello_payload(@client.BoardReplica::empty())) {
    Ok(Hello(hello)) => {
      assert_false(hello.has_board_snapshot)
      assert_eq(hello.last_seq, 0L)
    }
    _ => fail("expected Hello frame")
  }
}

///|
test "select values resolve through the centralized wire spellings" {
  assert_true(priority_from_wire("normal") is Some(Normal))
  assert_true(priority_from_wire("critical") is Some(Critical))
  // Unknown select values never invent a priority.
  assert_true(priority_from_wire("urgent") is None)
  assert_true(priority_from_wire("") is None)
}

///|
test "mutation gates require online authoritative and a free slot" {
  let connecting = Model::empty(true)
  assert_false(mutations_allowed(connecting))
  let offline = Model::empty(false)
  assert_false(mutations_allowed(offline))
  let online = seeded_online("t", "ready")
  assert_true(mutations_allowed(online))
  assert_false(mutations_allowed({ ..online, pending: Some(pending_probe()), }))
}

///|
fn pending_probe() -> PendingCommand {
  { command_id: "cmd-probe", kind: PendingCreate, revision: 0L, }
}

///|
test "rejection text maps stable codes to safe phrasing only" {
  assert_eq(
    rejection_text(Some("task_not_found")),
    "That task no longer exists on the board.",
  )
  assert_eq(
    rejection_text(Some("persistence_failed")),
    "The board could not save this change. Nothing was retried.",
  )
  // Unknown codes collapse to the generic sentence.
  assert_eq(
    rejection_text(Some("internal_store_detail")),
    "The board rejected this change.",
  )
  assert_eq(rejection_text(None), "The board rejected this change.")
}

///|
test "accepted commands close only the matching editor" {
  let create_draft = Editor::create()
  let edit_draft : Editor = {
    mode: EditMode(task_id="t"),
    title: "T",
    description: "",
    priority: Normal,
    definition_of_done: "",
  }
  // Accepted create closes a create draft but never an edit draft.
  assert_true(close_matching_editor(Some(create_draft), PendingCreate) is None)
  assert_true(close_matching_editor(Some(edit_draft), PendingCreate) is Some(_))
  // Accepted edit closes only the same task's draft.
  assert_true(
    close_matching_editor(Some(edit_draft), PendingEdit(task_id="t")) is None,
  )
  assert_true(
    close_matching_editor(Some(edit_draft), PendingEdit(task_id="other"))
    is Some(_),
  )
  // Moves leave every editor untouched.
  assert_true(
    close_matching_editor(Some(edit_draft), PendingMove(task_id="t", to=Done))
    is Some(_),
  )
}
