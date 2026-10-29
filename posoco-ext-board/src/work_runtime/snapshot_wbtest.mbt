///|
fn snapshot_test_state(
  tasks : Json,
  attempts? : Json,
) -> @board_protocol.BoardSnapshot {
  let board : Map[String, Json] = Map::from_array([
    (
      "board",
      Json::object({
        "tasks": tasks,
        "attempts": match attempts {
          Some(value) => value
          None => Json::array([])
        },
      }),
    ),
  ])
  {
    protocol_version: 1,
    last_seq: 0L,
    board_revision: 3L,
    payload: Json::object(board),
  }
}

///|
test "full snapshot state needs tasks and attempts arrays" {
  let good = snapshot_test_state(Json::array([]), attempts=Json::array([]))
  let state = match BoardState::from_snapshot(good) {
    Ok(state) => state
    Err(error) => fail("a well-formed snapshot must read: " + error)
  }
  assert_eq(state.revision, 3L)
  let no_attempts : @board_protocol.BoardSnapshot = {
    protocol_version: 1,
    last_seq: 0L,
    board_revision: 3L,
    payload: Json::object({
      "board": Json::object({ "tasks": Json::array([]) }),
    }),
  }
  match BoardState::from_snapshot(no_attempts) {
    Err("board snapshot has no attempt array") => ()
    _ => fail("a snapshot without attempts must be rejected")
  }
  let no_tasks = snapshot_test_state(
    Json::object({ "attempts": Json::array([]) }),
  )
  match BoardState::from_snapshot(no_tasks) {
    Err("board snapshot has no task array") => ()
    _ => fail("a snapshot without tasks must be rejected")
  }
  let no_board : @board_protocol.BoardSnapshot = {
    protocol_version: 1,
    last_seq: 0L,
    board_revision: 0L,
    payload: Json::object({ "other": Json::array([]) }),
  }
  match BoardState::from_snapshot(no_board) {
    Err("board snapshot has no board object") => ()
    _ => fail("a snapshot without a board object must be rejected")
  }
  let junk : @board_protocol.BoardSnapshot = {
    protocol_version: 1,
    last_seq: 0L,
    board_revision: 0L,
    payload: Json::string("nope"),
  }
  match BoardState::from_snapshot(junk) {
    Err("board snapshot payload is invalid") => ()
    _ => fail("a non-object payload must be rejected")
  }
}

///|
test "tasks-only reading ignores a missing attempts array" {
  let snapshot = snapshot_test_state(Json::array([]))
  let state = match BoardState::tasks_from_snapshot(snapshot) {
    Ok(state) => state
    Err(error) => fail("tasks-only read must succeed: " + error)
  }
  assert_eq(state.revision, 3L)
}

///|
test "snapshot state finds tasks, stages and dependencies" {
  let tasks = Json::array([
    Json::object({
      "id": Json::string("task-1"),
      "stage": Json::string("ready"),
      "definition_of_done": Json::array([
        Json::string("evidence"),
        Json::string(""),
        Json::number(1.0),
      ]),
      "review_feedback": Json::string("  "),
      "dependencies": Json::array([]),
      "model": Json::object({
        "slot": Json::string("test/slot"),
        "effort": Json::null(),
      }),
    }),
    Json::object({
      "id": Json::string("task-2"),
      "stage": Json::string("refining"),
      "dependencies": Json::array([Json::string("task-1")]),
    }),
  ])
  let state = match
    BoardState::from_snapshot(
      snapshot_test_state(tasks, attempts=Json::array([])),
    ) {
    Ok(state) => state
    Err(error) => fail("fixture snapshot must read: " + error)
  }
  let task = match state.task("task-1") {
    Some(task) => task
    None => fail("task-1 must be found")
  }
  assert_eq(task_field(task, "stage"), "ready")
  assert_eq(state.stage("task-2"), "refining")
  assert_eq(state.stage("missing"), "")
  assert_eq(task_definition_of_done(task), ["evidence"])
  assert_true(task_review_feedback(task) is None)
  assert_true(state.has_dependents("task-1"))
  assert_false(state.has_dependents("task-2"))
  match task_model(task) {
    Some(pin) => {
      assert_eq(pin.slot, "test/slot")
      assert_true(pin.effort is None)
    }
    None => fail("the pinned model must be read")
  }
  assert_eq(
    model_pin_json(task_model(task)),
    Json::object({ "slot": Json::string("test/slot"), "effort": Json::null() }),
  )
  assert_eq(model_pin_json(None), Json::null())
}

///|
test "latest running review attempt prefers the newest creation" {
  let tasks = Json::array([
    Json::object({
      "id": Json::string("task-1"),
      "stage": Json::string("review"),
    }),
  ])
  let attempts = Json::array([
    Json::object({
      "id": Json::string("attempt-old"),
      "task_id": Json::string("task-1"),
      "kind": Json::string("review"),
      "status": Json::string("completed"),
      "created_at_ms": Json::number(10.0),
    }),
    Json::object({
      "id": Json::string("attempt-first"),
      "task_id": Json::string("task-1"),
      "kind": Json::string("review"),
      "status": Json::string("running"),
      "created_at_ms": Json::number(20.0),
    }),
    Json::object({
      "id": Json::string("attempt-second"),
      "task_id": Json::string("task-1"),
      "kind": Json::string("review"),
      "status": Json::string("running"),
      "created_at_ms": Json::number(20.0),
    }),
    Json::object({
      "id": Json::string("attempt-other"),
      "task_id": Json::string("task-2"),
      "kind": Json::string("review"),
      "status": Json::string("running"),
      "created_at_ms": Json::number(30.0),
    }),
  ])
  let state = match
    BoardState::from_snapshot(snapshot_test_state(tasks, attempts~)) {
    Ok(state) => state
    Err(error) => fail("fixture snapshot must read: " + error)
  }
  assert_eq(
    state.latest_running_review_attempt("task-1"),
    Some("attempt-second"),
  )
  assert_true(state.latest_running_review_attempt("task-3") is None)
}

///|
test "task required roles defaults to all and rejects plans without RD" {
  assert_eq(task_required_roles({}), ["rd", "set", "te"])
  assert_eq(task_required_roles({ "required_roles": ["rd"] }), ["rd"])
  assert_eq(task_required_roles({ "required_roles": ["set", "te"] }), [
    "rd", "set", "te",
  ])
}
