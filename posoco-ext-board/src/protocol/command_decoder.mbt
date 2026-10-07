///|
/// S3B2B2 pure wire command decoder: one `BoardClientCommand` frame becomes
/// exactly one typed `@domain.BoardCommand`, or a typed rejection. The
/// decoder is total, synchronous and side-effect free: it reads only the
/// frame and the caller-supplied `at_ms`, never a clock, the store or the
/// domain state. Validation is purely structural — frame identity, the fixed
/// eight-name table and the per-command args schema. Every semantic rule
/// (existence, transitions, cycles, duplicates, empty identifiers, no-op
/// updates) stays with the domain's `propose`.

///|
/// Internal schema violation; becomes the rejection `reason` at the top
/// level, wrapped with the frame's correlation id.
priv suberror SchemaError {
  Schema(String)
}

///|
fn args_object(args : Json) -> Map[String, Json] raise SchemaError {
  match args {
    Json::Object(fields) => fields
    _ => raise Schema("args must be a JSON object")
  }
}

///|
/// Payloads cannot smuggle timestamps, revisions or future fields.
fn args_allowlist(
  fields : Map[String, Json],
  allowed : Array[String],
) -> Unit raise SchemaError {
  for key in fields.keys() {
    if !allowed.contains(key) {
      raise Schema("unknown field '\{key}'")
    }
  }
}

///|
fn args_string(
  fields : Map[String, Json],
  key : String,
) -> String raise SchemaError {
  match fields.get(key) {
    Some(Json::String(value)) => value
    Some(_) => raise Schema("field '\{key}' must be a string")
    None => raise Schema("missing field '\{key}'")
  }
}

///|
/// Emptiness stays legal: a domain concern, not a wire schema one.
fn args_task_id(
  fields : Map[String, Json],
  key : String,
) -> @domain.BoardTaskId raise SchemaError {
  @domain.BoardTaskId(args_string(fields, key))
}

///|
fn args_attempt_id(
  fields : Map[String, Json],
  key : String,
) -> @domain.AttemptId raise SchemaError {
  @domain.AttemptId(args_string(fields, key))
}

///|
fn args_string_array(
  fields : Map[String, Json],
  key : String,
) -> Array[String] raise SchemaError {
  let values = match fields.get(key) {
    Some(Json::Array(values)) => values
    Some(_) => raise Schema("field '\{key}' must be an array of strings")
    None => raise Schema("missing field '\{key}'")
  }
  let items : Array[String] = []
  for value in values {
    match value {
      Json::String(item) => items.push(item)
      _ => raise Schema("field '\{key}' must contain only strings")
    }
  }
  items
}

///|
fn args_task_ids(
  fields : Map[String, Json],
  key : String,
) -> Array[@domain.BoardTaskId] raise SchemaError {
  args_string_array(fields, key).map(id => @domain.BoardTaskId(id))
}

///|
/// Update-only: absent means unchanged; an explicit null is invalid.
fn args_optional_string(
  fields : Map[String, Json],
  key : String,
) -> String? raise SchemaError {
  match fields.get(key) {
    None => None
    Some(Json::String(value)) => Some(value)
    Some(Json::Null) =>
      raise Schema(
        "field '\{key}' must not be null; omit it to keep the current value",
      )
    Some(_) => raise Schema("field '\{key}' must be a string")
  }
}

///|
fn args_optional_string_array(
  fields : Map[String, Json],
  key : String,
) -> Array[String]? raise SchemaError {
  match fields.get(key) {
    None => None
    Some(Json::Null) =>
      raise Schema(
        "field '\{key}' must not be null; omit it to keep the current value",
      )
    Some(_) => Some(args_string_array(fields, key))
  }
}

///|
fn args_priority(
  fields : Map[String, Json],
  key : String,
) -> @domain.BoardPriority raise SchemaError {
  match args_string(fields, key) {
    "low" => Low
    "normal" => Normal
    "high" => High
    "critical" => Critical
    _ =>
      raise Schema("field '\{key}' must be one of: low, normal, high, critical")
  }
}

///|
fn args_optional_priority(
  fields : Map[String, Json],
  key : String,
) -> @domain.BoardPriority? raise SchemaError {
  match fields.get(key) {
    None => None
    Some(Json::Null) =>
      raise Schema(
        "field '\{key}' must not be null; omit it to keep the current value",
      )
    Some(_) => Some(args_priority(fields, key))
  }
}

///|
fn args_stage(
  fields : Map[String, Json],
  key : String,
) -> @domain.BoardStage raise SchemaError {
  match args_string(fields, key) {
    "created" => Created
    "refining" => Refining
    "ready" => Ready
    "running" => Running
    "review" => Review
    "done" => Done
    "suspended" => Suspended
    _ =>
      raise Schema(
        "field '\{key}' must be one of: created, refining, ready, running, review, done, suspended",
      )
  }
}

///|
fn args_kind(
  fields : Map[String, Json],
  key : String,
) -> @domain.AttemptKind raise SchemaError {
  match args_string(fields, key) {
    "discuss" => Discuss
    "execute" => Execute
    "review" => Review
    _ => raise Schema("field '\{key}' must be one of: discuss, execute, review")
  }
}

///|
fn args_outcome(
  fields : Map[String, Json],
  key : String,
) -> @domain.AttemptOutcome raise SchemaError {
  match args_string(fields, key) {
    "succeeded" => Succeeded
    "failed" => Failed
    "cancelled" => Cancelled
    "interrupted" => Interrupted
    _ =>
      raise Schema(
        "field '\{key}' must be one of: succeeded, failed, cancelled, interrupted",
      )
  }
}

///|
/// A recordable review decision. `pending` is deliberately not on the wire:
/// Pending is the implicit state when a review attempt starts running; only
/// Approved or ChangesRequested can ever be recorded.
fn args_decision(
  fields : Map[String, Json],
  key : String,
) -> @domain.ReviewDecision raise SchemaError {
  match args_string(fields, key) {
    "approved" => Approved
    "changes_requested" => ChangesRequested
    _ =>
      raise Schema("field '\{key}' must be one of: approved, changes_requested")
  }
}

///|
/// `board.task.create`: every field is required.
fn decode_create_task(
  fields : Map[String, Json],
  at_ms : Int64,
  expected_revision : Int64,
) -> @domain.BoardCommand raise SchemaError {
  args_allowlist(fields, [
    "id", "title", "description", "priority", "definition_of_done", "dependencies",
  ])
  let id = args_task_id(fields, "id")
  let title = args_string(fields, "title")
  let description = args_string(fields, "description")
  let priority = args_priority(fields, "priority")
  let definition_of_done = args_string_array(fields, "definition_of_done")
  let dependencies = args_task_ids(fields, "dependencies")
  @domain.CreateTask(
    id~,
    title~,
    description~,
    priority~,
    definition_of_done~,
    dependencies~,
    at_ms~,
    expected_revision~,
  )
}

///|
/// `board.task.update`: `id` is required, everything else is optional by
/// absence.
fn decode_update_task(
  fields : Map[String, Json],
  at_ms : Int64,
  expected_revision : Int64,
) -> @domain.BoardCommand raise SchemaError {
  args_allowlist(fields, [
    "id", "title", "description", "priority", "definition_of_done",
  ])
  let id = args_task_id(fields, "id")
  let title = args_optional_string(fields, "title")
  let description = args_optional_string(fields, "description")
  let priority = args_optional_priority(fields, "priority")
  let definition_of_done = args_optional_string_array(
    fields, "definition_of_done",
  )
  @domain.UpdateTask(
    id~,
    title~,
    description~,
    priority~,
    definition_of_done~,
    at_ms~,
    expected_revision~,
  )
}

///|
fn decode_set_dependencies(
  fields : Map[String, Json],
  at_ms : Int64,
  expected_revision : Int64,
) -> @domain.BoardCommand raise SchemaError {
  args_allowlist(fields, ["id", "dependencies"])
  let id = args_task_id(fields, "id")
  let dependencies = args_task_ids(fields, "dependencies")
  @domain.SetDependencies(id~, dependencies~, at_ms~, expected_revision~)
}

///|
fn decode_move_task(
  fields : Map[String, Json],
  at_ms : Int64,
  expected_revision : Int64,
) -> @domain.BoardCommand raise SchemaError {
  args_allowlist(fields, ["id", "to"])
  let id = args_task_id(fields, "id")
  let to = args_stage(fields, "to")
  @domain.MoveTask(id~, to~, at_ms~, expected_revision~)
}

///|
fn decode_queue_attempt(
  fields : Map[String, Json],
  at_ms : Int64,
  expected_revision : Int64,
) -> @domain.BoardCommand raise SchemaError {
  args_allowlist(fields, ["id", "task_id", "kind"])
  let id = args_attempt_id(fields, "id")
  let task = args_task_id(fields, "task_id")
  let kind = args_kind(fields, "kind")
  @domain.QueueAttempt(id~, task~, kind~, at_ms~, expected_revision~)
}

///|
fn decode_start_attempt(
  fields : Map[String, Json],
  at_ms : Int64,
  expected_revision : Int64,
) -> @domain.BoardCommand raise SchemaError {
  args_allowlist(fields, ["id"])
  let id = args_attempt_id(fields, "id")
  @domain.StartAttempt(id~, at_ms~, expected_revision~)
}

///|
fn decode_finish_attempt(
  fields : Map[String, Json],
  at_ms : Int64,
  expected_revision : Int64,
) -> @domain.BoardCommand raise SchemaError {
  args_allowlist(fields, ["id", "outcome"])
  let id = args_attempt_id(fields, "id")
  let outcome = args_outcome(fields, "outcome")
  @domain.FinishAttempt(id~, outcome~, at_ms~, expected_revision~)
}

///|
fn decode_record_review(
  fields : Map[String, Json],
  at_ms : Int64,
  expected_revision : Int64,
) -> @domain.BoardCommand raise SchemaError {
  args_allowlist(fields, ["id", "decision"])
  let id = args_attempt_id(fields, "id")
  let decision = args_decision(fields, "decision")
  @domain.RecordReview(id~, decision~, at_ms~, expected_revision~)
}

///|
/// The fixed wire surface. One row per command name; the parsers reject
/// every schema deviation as `InvalidArguments`.
fn command_parser(
  name : String,
) -> ((Map[String, Json], Int64, Int64) -> @domain.BoardCommand raise SchemaError)? {
  match name {
    "board.task.create" => Some(decode_create_task)
    "board.task.update" => Some(decode_update_task)
    "board.task.set_dependencies" => Some(decode_set_dependencies)
    "board.task.move" => Some(decode_move_task)
    "board.attempt.queue" => Some(decode_queue_attempt)
    "board.attempt.start" => Some(decode_start_attempt)
    "board.attempt.finish" => Some(decode_finish_attempt)
    "board.review.record" => Some(decode_record_review)
    _ => None
  }
}

///|
/// Decode one client command frame into its typed domain command.
///
/// `expected_revision` is carried through from the frame unchanged and
/// `at_ms` is taken only from the argument: the decoder owns no clock and
/// accepts no timestamp or revision from the payload. Rejections correlate:
/// both cases carry the frame's `command_id`, so a caller can always answer
/// the exact frame, even when that id is empty. The command name must be one
/// of the eight fixed names; an empty `command_id` or an unknown name is
/// `InvalidCommand` (no schema can be selected), every args schema deviation
/// is `InvalidArguments`.
///
/// # Example
/// ```mbt check
/// test {
///   let wire : @protocol.BoardClientCommand = {
///     command_id: "c-1",
///     name: "board.attempt.start",
///     expected_revision: 4L,
///     args: Json::object({ "id": Json::string("a-1") }),
///   }
///   assert_eq(
///     @protocol.decode_board_command(wire, 1000L),
///     Ok(
///       @domain.StartAttempt(
///         id=@domain.AttemptId("a-1"),
///         at_ms=1000L,
///         expected_revision=4L,
///       ),
///     ),
///   )
/// }
/// ```
pub fn decode_board_command(
  wire : BoardClientCommand,
  at_ms : Int64,
) -> Result[@domain.BoardCommand, BoardCommandDecodeError] {
  // Frame identity first: an empty correlation id or an unknown name means
  // the command the frame claims to be cannot be trusted, so no schema is
  // applied and args are not inspected.
  if wire.command_id == "" {
    return Err(
      InvalidCommand(
        command_id=wire.command_id,
        reason="command_id must not be empty",
      ),
    )
  }
  let parse = match command_parser(wire.name) {
    Some(parse) => parse
    None =>
      return Err(
        InvalidCommand(
          command_id=wire.command_id,
          reason="unknown command name '\{wire.name}'",
        ),
      )
  }
  try {
    let fields = args_object(wire.args)
    Ok(parse(fields, at_ms, wire.expected_revision))
  } catch {
    Schema(reason) =>
      Err(InvalidArguments(command_id=wire.command_id, name=wire.name, reason~))
  }
}
