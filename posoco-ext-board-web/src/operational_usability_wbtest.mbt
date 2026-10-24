///|
test "working vocabulary names stages by what a person does" {
  assert_eq(ui_stage_label(Created), "Backlog")
  assert_eq(ui_stage_label(Refining), "Shaping")
  assert_eq(ui_stage_label(Running), "In progress")
  assert_eq(ui_stage_label(Review), "In review")
  assert_eq(ui_stage_label(Suspended), "Paused")
  assert_eq(ui_stage_label(Cancelled), "Cancelled")
  assert_eq(primary_action_label(Ready), "Start work")
  assert_eq(primary_action_label(Review), "Mark done")
  assert_eq(primary_action_label(Suspended), "Resume")
  assert_true(primary_move(Review) == Done)
  assert_true(primary_move(Suspended) == Ready)
  // Cancelled is terminal: no forward move, so the views render no action.
  assert_true(primary_move(Cancelled) == Cancelled)
}

///|
test "write hints distinguish connection states without leaking detail" {
  let model = seeded_online("t", "ready")
  assert_true(write_blocked_hint(model) is None)
  assert_true(
    write_blocked_hint(Model::empty(true)).unwrap().contains("Connecting"),
  )
  let retained = { ..model, connection: Reconnecting, }
  assert_true(write_blocked_hint(retained).unwrap().contains("Reconnecting"))
  let terminal = {
    ..model,
    connection: ProtocolError("secret transport payload"),
  }
  let message = write_blocked_hint(terminal).unwrap()
  assert_true(message.contains("Connection stopped"))
  assert_false(message.contains("secret transport payload"))
  assert_true(
    write_blocked_hint({ ..model, connection: Offline, })
    .unwrap()
    .contains("Offline"),
  )
}

///|
test "hidden inspector notice and section navigation do not mutate intent" {
  let model = draft_model()
  let (hidden, command) = update(
    model,
    FilterQueryChanged("no match"),
    test_emit,
    test_env(),
  )
  debug_inspect(command, content="[]")
  assert_true(
    selection_filter_note(hidden)
    .unwrap()
    .contains("details and drafts remain available"),
  )
  assert_true(inspector_task(hidden) is Some(_))
  assert_true(hidden.replica == model.replica)
  assert_true(hidden.dependency_editor == model.dependency_editor)
  let invalidated = { ..hidden, replica: @client.BoardReplica::empty(), }
  assert_true(selection_filter_note(invalidated) is None)
  assert_true(inspector_task(invalidated) is None)
  let (cleared, _) = update(hidden, FiltersCleared, test_emit, test_env())
  assert_true(selection_filter_note(cleared) is None)
  assert_eq(cleared.selected_task, model.selected_task)
}

///|
test "authoritative task event changes filter membership without changing search intent" {
  let model = {
    ..filter_model(sample_filter_tasks()),
    task_filter: {
      ..TaskFilter::none(),
      query: "urgent",
      priority: Some(High),
    },
    selected_task: Some("t2"),
  }
  assert_eq(visible_tasks(model.replica, model.task_filter).length(), 0)
  let entity = filter_task_json(
    "t2", "URGENT repair", "new description", "created", "high", 10,
  )
  let frame = @protocol.encode_server_frame(
    Event({
      seq: 1L,
      board_revision: 2L,
      kind: "board.task.updated",
      scope: None,
      payload: { "task_id": "t2", "at_ms": 1234, "task": entity },
    }),
  )
  let (updated, _) = update(
    model,
    SocketEvent(0, Message(frame)),
    test_emit,
    test_env(),
  )
  assert_eq(
    visible_tasks(updated.replica, updated.task_filter).map(task => task.id),
    ["t2"],
  )
  assert_true(updated.task_filter == model.task_filter)
  assert_eq(updated.selected_task, model.selected_task)
  assert_eq(updated.replica.revision(), 2L)
  assert_eq(updated.replica.last_seq(), 1L)
  assert_eq(model.replica.revision(), 1L)
  assert_eq(model.replica.last_seq(), 0L)
  assert_eq(visible_tasks(model.replica, model.task_filter).length(), 0)
}
