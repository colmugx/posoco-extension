///|
test "operational vocabulary distinguishes manual stages decisions and execution" {
  let explanation = manual_lifecycle_note()
  assert_true(explanation.contains("Agent execution: Not connected"))
  assert_true(
    explanation.contains("Task Done does not verify execution success"),
  )
  assert_true(
    explanation.contains("Review Approved does not finish an attempt"),
  )
  let model = submitted_review()
  let before = model.replica.copy()
  assert_true(model.pending is Some(_))
  assert_true(
    mutation_availability_note(model)
    .unwrap()
    .contains("until this command settles"),
  )
  assert_true(model.replica == before)
}

///|
test "unavailable mutation reasons distinguish retained state and terminal user action" {
  let model = seeded_online("t", "ready")
  assert_true(mutation_availability_note(model) is None)
  assert_true(
    mutation_availability_note(Model::empty(true))
    .unwrap()
    .contains("connecting"),
  )
  let retained = { ..model, connection: Reconnecting, }
  assert_true(
    mutation_availability_note(retained)
    .unwrap()
    .contains("reference, not as live state"),
  )
  let invalidated = { ..retained, replica: @client.BoardReplica::empty(), }
  assert_true(
    mutation_availability_note(invalidated)
    .unwrap()
    .contains("fresh authoritative snapshot"),
  )
  let terminal = {
    ..model,
    connection: ProtocolError("secret transport payload"),
  }
  let message = mutation_availability_note(terminal).unwrap()
  assert_true(message.contains("check host compatibility"))
  assert_true(message.contains("before reloading"))
  assert_false(message.contains("secret transport payload"))
  assert_true(
    mutation_availability_note({ ..model, connection: Offline, })
    .unwrap()
    .contains("offline"),
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
  assert_eq(inspector_sections(), [
    ("inspector-task-details", "Task details"),
    ("inspector-dependencies", "Dependencies"),
    ("inspector-attempts", "Attempts and reviews"),
  ])
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
