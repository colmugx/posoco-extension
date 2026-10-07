///|
/// Decoder tests for the fixed eight-command wire surface. Every rejection
/// test goes through the shared helpers so correlation, the stable code and
/// the reason non-emptiness are pinned on every case, not just once.

///|
fn decoder_task_id(value : String) -> @domain.BoardTaskId {
  @domain.BoardTaskId(value)
}

///|
fn decoder_attempt_id(value : String) -> @domain.AttemptId {
  @domain.AttemptId(value)
}

///|
fn decoder_wire(
  name : String,
  args : Json,
  command_id? : String = "c-1",
  expected_revision? : Int64 = 7L,
) -> BoardClientCommand {
  { command_id, name, expected_revision, args, }
}

///|
/// A fresh, schema-valid minimal payload for one command name. Values that
/// the domain would reject (empty ids, empty arrays) are deliberately not
/// used here: the wire schema knows no business rules.
fn decoder_valid_fields(name : String) -> Map[String, Json] raise {
  let fields : Map[String, Json] = Map::from_array([])
  match name {
    "board.task.create" => {
      fields["id"] = Json::string("t-1")
      fields["title"] = Json::string("Ship the decoder")
      fields["description"] = Json::string("Wire surface for the board")
      fields["priority"] = Json::string("high")
      fields["definition_of_done"] = Json::array([Json::string("tests pass")])
      fields["dependencies"] = Json::array([
        Json::string("t-2"),
        Json::string("t-3"),
      ])
    }
    "board.task.update" => fields["id"] = Json::string("t-1")
    "board.task.set_dependencies" => {
      fields["id"] = Json::string("t-1")
      fields["dependencies"] = Json::array([Json::string("t-2")])
    }
    "board.task.move" => {
      fields["id"] = Json::string("t-1")
      fields["to"] = Json::string("ready")
    }
    "board.attempt.queue" => {
      fields["id"] = Json::string("a-1")
      fields["task_id"] = Json::string("t-1")
      fields["kind"] = Json::string("execute")
    }
    "board.attempt.start" => fields["id"] = Json::string("a-1")
    "board.attempt.finish" => {
      fields["id"] = Json::string("a-1")
      fields["outcome"] = Json::string("failed")
    }
    "board.review.record" => {
      fields["id"] = Json::string("a-1")
      fields["decision"] = Json::string("approved")
    }
    _ => fail("unknown command name in test fixture")
  }
  fields
}

///|
fn decoder_valid_args(name : String) -> Json raise {
  Json::object(decoder_valid_fields(name))
}

///|
/// The full create payload with one key dropped, for missing-field tests.
fn decoder_create_args(exclude : String) -> Json raise {
  let fields = decoder_valid_fields("board.task.create")
  fields.remove(exclude)
  Json::object(fields)
}

///|
fn decoder_ok(
  wire : BoardClientCommand,
  expected : @domain.BoardCommand,
  at_ms? : Int64 = 1000L,
) -> Unit raise {
  assert_eq(decode_board_command(wire, at_ms), Ok(expected))
}

///|
/// Asserts one InvalidArguments rejection: correlated to the frame, with a
/// non-empty reason and the stable invalid_arguments wire code.
fn decoder_args_error(
  wire : BoardClientCommand,
  at_ms? : Int64 = 1000L,
) -> Unit raise {
  match decode_board_command(wire, at_ms) {
    Err(InvalidArguments(command_id~, name~, reason~)) => {
      assert_eq(command_id, wire.command_id)
      assert_eq(name, wire.name)
      assert_true(reason != "")
      assert_eq(
        InvalidArguments(command_id~, name~, reason~).code(),
        "invalid_arguments",
      )
    }
    Err(_) => fail("expected InvalidArguments")
    Ok(_) => fail("args schema violation must be rejected")
  }
}

///|
/// Asserts one InvalidCommand rejection: correlated to the frame even when
/// that correlation id is empty, with the stable invalid_command code.
fn decoder_command_error(
  wire : BoardClientCommand,
  at_ms? : Int64 = 1000L,
) -> Unit raise {
  match decode_board_command(wire, at_ms) {
    Err(InvalidCommand(command_id~, reason~)) => {
      assert_eq(command_id, wire.command_id)
      assert_true(reason != "")
      assert_eq(InvalidCommand(command_id~, reason~).code(), "invalid_command")
    }
    Err(_) => fail("expected InvalidCommand")
    Ok(_) => fail("frame-level violation must be rejected")
  }
}

///|
test "board.task.create requires every field" {
  decoder_ok(
    decoder_wire("board.task.create", decoder_valid_args("board.task.create")),
    @domain.CreateTask(
      id=decoder_task_id("t-1"),
      title="Ship the decoder",
      description="Wire surface for the board",
      priority=@domain.High,
      definition_of_done=["tests pass"],
      dependencies=[decoder_task_id("t-2"), decoder_task_id("t-3")],
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
  for
    key in [
      "id", "title", "description", "priority", "definition_of_done", "dependencies",
    ] {
    decoder_args_error(
      decoder_wire("board.task.create", decoder_create_args(key)),
    )
  }
}

///|
test "board.task.update treats absence as unchanged and null as invalid" {
  decoder_ok(
    decoder_wire(
      "board.task.update",
      Json::object({
        "id": Json::string("t-1"),
        "title": Json::string("Renamed"),
        "description": Json::string("Reworded"),
        "priority": Json::string("low"),
        "definition_of_done": Json::array([Json::string("reviewed")]),
      }),
    ),
    @domain.UpdateTask(
      id=decoder_task_id("t-1"),
      title=Some("Renamed"),
      description=Some("Reworded"),
      priority=Some(@domain.Low),
      definition_of_done=Some(["reviewed"]),
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
  decoder_ok(
    decoder_wire(
      "board.task.update",
      Json::object({ "id": Json::string("t-1") }),
    ),
    @domain.UpdateTask(
      id=decoder_task_id("t-1"),
      title=None,
      description=None,
      priority=None,
      definition_of_done=None,
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
  decoder_ok(
    decoder_wire("board.task.update", { "id": "t-1", "definition_of_done": [] }),
    @domain.UpdateTask(
      id=decoder_task_id("t-1"),
      title=None,
      description=None,
      priority=None,
      definition_of_done=Some([]),
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
  // Omission is the only way to leave a value unchanged: an explicit null
  // is a schema violation for every optional field.
  for key in ["title", "description", "priority", "definition_of_done"] {
    let fields = decoder_valid_fields("board.task.update")
    fields[key] = Json::null()
    decoder_args_error(decoder_wire("board.task.update", Json::object(fields)))
  }
  for
    (key, value) in [
      ("title", Json::number(1)),
      ("description", Json::array([])),
      ("priority", Json::string("URGENT")),
      ("definition_of_done", Json::object({})),
    ] {
    let fields = decoder_valid_fields("board.task.update")
    fields[key] = value
    decoder_args_error(decoder_wire("board.task.update", Json::object(fields)))
  }
}

///|
test "board.task.set_dependencies and board.task.move decode strictly" {
  decoder_ok(
    decoder_wire(
      "board.task.set_dependencies",
      decoder_valid_args("board.task.set_dependencies"),
    ),
    @domain.SetDependencies(
      id=decoder_task_id("t-1"),
      dependencies=[decoder_task_id("t-2")],
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
  decoder_ok(
    decoder_wire("board.task.move", decoder_valid_args("board.task.move")),
    @domain.MoveTask(
      id=decoder_task_id("t-1"),
      to=@domain.Ready,
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
  // set_dependencies: missing id, missing array, array of the wrong shape.
  decoder_args_error(
    decoder_wire("board.task.set_dependencies", Json::object({})),
  )
  decoder_args_error(
    decoder_wire(
      "board.task.set_dependencies",
      Json::object({ "id": Json::string("t-1") }),
    ),
  )
  decoder_args_error(
    decoder_wire(
      "board.task.set_dependencies",
      Json::object({
        "id": Json::string("t-1"),
        "dependencies": Json::string("t-2"),
      }),
    ),
  )
  // move: missing target, null id, unknown field.
  decoder_args_error(
    decoder_wire("board.task.move", Json::object({ "id": Json::string("t-1") })),
  )
  decoder_args_error(
    decoder_wire(
      "board.task.move",
      Json::object({ "id": Json::null(), "to": Json::string("ready") }),
    ),
  )
  decoder_args_error(
    decoder_wire(
      "board.task.move",
      Json::object({
        "id": Json::string("t-1"),
        "to": Json::string("ready"),
        "from": Json::string("created"),
      }),
    ),
  )
}

///|
test "attempt and review commands decode with strict ids and enums" {
  decoder_ok(
    decoder_wire(
      "board.attempt.queue",
      decoder_valid_args("board.attempt.queue"),
    ),
    @domain.QueueAttempt(
      id=decoder_attempt_id("a-1"),
      task=decoder_task_id("t-1"),
      kind=@domain.Execute,
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
  decoder_ok(
    decoder_wire(
      "board.attempt.start",
      Json::object({ "id": Json::string("a-1") }),
    ),
    @domain.StartAttempt(
      id=decoder_attempt_id("a-1"),
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
  decoder_ok(
    decoder_wire(
      "board.attempt.finish",
      decoder_valid_args("board.attempt.finish"),
    ),
    @domain.FinishAttempt(
      id=decoder_attempt_id("a-1"),
      outcome=@domain.Failed,
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
  decoder_ok(
    decoder_wire(
      "board.review.record",
      decoder_valid_args("board.review.record"),
    ),
    @domain.RecordReview(
      id=decoder_attempt_id("a-1"),
      decision=@domain.Approved,
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
  // queue: missing task_id, wrong task_id type, domain label `task` alone
  // is not on the wire.
  decoder_args_error(
    decoder_wire(
      "board.attempt.queue",
      Json::object({
        "id": Json::string("a-1"),
        "kind": Json::string("execute"),
      }),
    ),
  )
  decoder_args_error(
    decoder_wire(
      "board.attempt.queue",
      Json::object({
        "id": Json::string("a-1"),
        "task_id": Json::boolean(false),
        "kind": Json::string("execute"),
      }),
    ),
  )
  decoder_args_error(
    decoder_wire(
      "board.attempt.queue",
      Json::object({
        "id": Json::string("a-1"),
        "task": Json::string("t-1"),
        "task_id": Json::string("t-1"),
        "kind": Json::string("execute"),
      }),
    ),
  )
  // start: missing id, wrong id type, unknown field.
  decoder_args_error(decoder_wire("board.attempt.start", Json::object({})))
  decoder_args_error(
    decoder_wire(
      "board.attempt.start",
      Json::object({ "id": Json::number(12) }),
    ),
  )
  decoder_args_error(
    decoder_wire(
      "board.attempt.start",
      Json::object({ "id": Json::string("a-1"), "task": Json::string("t-1") }),
    ),
  )
  // finish: missing outcome, null outcome.
  decoder_args_error(
    decoder_wire(
      "board.attempt.finish",
      Json::object({ "id": Json::string("a-1") }),
    ),
  )
  decoder_args_error(
    decoder_wire(
      "board.attempt.finish",
      Json::object({ "id": Json::string("a-1"), "outcome": Json::null() }),
    ),
  )
  // review: missing decision, wrong decision type.
  decoder_args_error(
    decoder_wire(
      "board.review.record",
      Json::object({ "id": Json::string("a-1") }),
    ),
  )
  decoder_args_error(
    decoder_wire(
      "board.review.record",
      Json::object({ "id": Json::string("a-1"), "decision": Json::number(1) }),
    ),
  )
}

///|
test "unknown, empty and mistyped names are InvalidCommand" {
  for
    name in [
      "board.task.destroy", "", "Board.Task.Create", "board.task.create ", "runtime.ping",
    ] {
    decoder_command_error(
      decoder_wire(name, Json::object({ "id": Json::string("t-1") })),
    )
  }
}

///|
test "empty command_id is rejected but stays correlated" {
  decoder_command_error(
    decoder_wire(
      "board.attempt.start",
      decoder_valid_args("board.attempt.start"),
      command_id="",
    ),
  )
  // An empty id plus an unknown name still correlates the empty id through.
  decoder_command_error(
    decoder_wire("no.such.command", Json::object({}), command_id=""),
  )
  match
    decode_board_command(
      decoder_wire("board.task.move", Json::object({}), command_id=""),
      1000L,
    ) {
    Err(InvalidCommand(command_id~, reason~)) => {
      assert_eq(command_id, "")
      assert_true(reason != "")
    }
    Err(_) => fail("expected InvalidCommand")
    Ok(_) => fail("empty command_id must be rejected")
  }
}

///|
test "args must be a JSON object for every known name" {
  for
    name in [
      "board.task.create", "board.task.update", "board.task.set_dependencies", "board.task.move",
      "board.attempt.queue", "board.attempt.start", "board.attempt.finish", "board.review.record",
    ] {
    for
      args in [
        Json::string("id"),
        Json::array([Json::string("id")]),
        Json::number(1),
        Json::boolean(true),
        Json::null(),
      ] {
      decoder_args_error(decoder_wire(name, args))
    }
  }
}

///|
test "create rejects wrong types, nulls, bad array items and unknown fields" {
  for
    (key, value) in [
      ("id", Json::number(1)),
      ("title", Json::null()),
      ("description", Json::boolean(true)),
      ("priority", Json::number(3)),
      ("definition_of_done", Json::string("tests pass")),
      ("dependencies", Json::object({})),
    ] {
    let fields = decoder_valid_fields("board.task.create")
    fields[key] = value
    decoder_args_error(decoder_wire("board.task.create", Json::object(fields)))
  }
  for
    poison in [
      Json::null(),
      Json::number(1),
      Json::boolean(false),
      Json::array([]),
      Json::object({}),
    ] {
    let fields = decoder_valid_fields("board.task.create")
    fields["definition_of_done"] = Json::array([
      Json::string("tests pass"),
      poison,
    ])
    decoder_args_error(decoder_wire("board.task.create", Json::object(fields)))
    let fields = decoder_valid_fields("board.task.create")
    fields["dependencies"] = Json::array([Json::string("t-2"), poison])
    decoder_args_error(decoder_wire("board.task.create", Json::object(fields)))
  }
  for extra in ["extra", "at_ms", "expected_revision"] {
    let fields = decoder_valid_fields("board.task.create")
    fields[extra] = Json::number(42)
    decoder_args_error(decoder_wire("board.task.create", Json::object(fields)))
  }
}

///|
test "enum strings are strict, lowercase snake_case and case sensitive" {
  for priority in ["urgent", "High", "normal ", ""] {
    let fields = decoder_valid_fields("board.task.create")
    fields["priority"] = Json::string(priority)
    decoder_args_error(decoder_wire("board.task.create", Json::object(fields)))
  }
  for stage in ["Ready", "archived", "pending", ""] {
    let fields = decoder_valid_fields("board.task.move")
    fields["to"] = Json::string(stage)
    decoder_args_error(decoder_wire("board.task.move", Json::object(fields)))
  }
  for kind in ["code", "Discuss", ""] {
    let fields = decoder_valid_fields("board.attempt.queue")
    fields["kind"] = Json::string(kind)
    decoder_args_error(
      decoder_wire("board.attempt.queue", Json::object(fields)),
    )
  }
  for outcome in ["success", "Succeeded", "aborted", ""] {
    let fields = decoder_valid_fields("board.attempt.finish")
    fields["outcome"] = Json::string(outcome)
    decoder_args_error(
      decoder_wire("board.attempt.finish", Json::object(fields)),
    )
  }
  // `pending` is deliberately off the wire: a review is recorded as
  // approved or changes_requested, nothing else.
  for decision in ["pending", "Approved", "changes", ""] {
    let fields = decoder_valid_fields("board.review.record")
    fields["decision"] = Json::string(decision)
    decoder_args_error(
      decoder_wire("board.review.record", Json::object(fields)),
    )
  }
}

///|
test "no payload can inject a timestamp or a revision" {
  let names : Array[String] = [
    "board.task.create", "board.task.update", "board.task.set_dependencies", "board.task.move",
    "board.attempt.queue", "board.attempt.start", "board.attempt.finish", "board.review.record",
  ]
  for name in names {
    for
      injected in [
        "at_ms", "expected_revision", "revision", "persistence", "titlle",
      ] {
      let fields = decoder_valid_fields(name)
      fields[injected] = Json::number(42)
      decoder_args_error(decoder_wire(name, Json::object(fields)))
    }
  }
}

///|
test "at_ms comes only from the argument and expected_revision only from the frame" {
  let wire = decoder_wire(
    "board.attempt.start",
    decoder_valid_args("board.attempt.start"),
    expected_revision=11L,
  )
  decoder_ok(
    wire,
    @domain.StartAttempt(
      id=decoder_attempt_id("a-1"),
      at_ms=55L,
      expected_revision=11L,
    ),
    at_ms=55L,
  )
  // The same frame under a different argument time moves the command time;
  // a negative time is a domain rejection, not a wire one.
  decoder_ok(
    wire,
    @domain.StartAttempt(
      id=decoder_attempt_id("a-1"),
      at_ms=-3L,
      expected_revision=11L,
    ),
    at_ms=-3L,
  )
}

///|
test "the decoder performs no domain business validation" {
  // Empty identifiers, an empty doD and a dependency on "" are all
  // well-formed wire values; rejecting them is the domain's job.
  decoder_ok(
    decoder_wire(
      "board.task.create",
      Json::object({
        "id": Json::string(""),
        "title": Json::string(""),
        "description": Json::string(""),
        "priority": Json::string("critical"),
        "definition_of_done": Json::array([]),
        "dependencies": Json::array([Json::string("")]),
      }),
    ),
    @domain.CreateTask(
      id=decoder_task_id(""),
      title="",
      description="",
      priority=@domain.Critical,
      definition_of_done=[],
      dependencies=[decoder_task_id("")],
      at_ms=1000L,
      expected_revision=7L,
    ),
  )
}

///|
test "rejection codes are stable wire strings" {
  assert_eq(
    InvalidCommand(command_id="c", reason="r").code(),
    "invalid_command",
  )
  assert_eq(
    InvalidArguments(command_id="c", name="board.task.move", reason="r").code(),
    "invalid_arguments",
  )
}
