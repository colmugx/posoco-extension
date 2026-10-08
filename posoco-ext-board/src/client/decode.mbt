///|
priv suberror DecodeFailure {
  DecodeFailure(String)
}

///|
fn fields(value : Json) -> Map[String, Json] raise DecodeFailure {
  match value {
    Object(value) => value
    _ => raise DecodeFailure("expected object")
  }
}

///|
fn required(obj : Map[String, Json], key : String) -> Json raise DecodeFailure {
  match obj.get(key) {
    Some(value) => value
    None => raise DecodeFailure("missing field: \{key}")
  }
}

///|
fn text(value : Json) -> String raise DecodeFailure {
  match value {
    String(value) => value
    _ => raise DecodeFailure("expected string")
  }
}

///|
fn integer(value : Json) -> Int64 raise DecodeFailure {
  match value {
    Number(value, ..) => {
      guard value >= 0.0 && value <= 9007199254740991.0 else {
        raise DecodeFailure("expected nonnegative safe integer")
      }
      guard value.to_int64().to_double() == value else {
        raise DecodeFailure("expected nonnegative safe integer")
      }
      value.to_int64()
    }
    _ => raise DecodeFailure("expected nonnegative safe integer")
  }
}

///|
fn safe_integer(value : Int64) -> Bool {
  value >= 0L && value <= 9007199254740991L
}

///|
fn nullable_integer(value : Json) -> Int64? raise DecodeFailure {
  match value {
    Null => None
    _ => Some(integer(value))
  }
}

///|
fn items(value : Json) -> Array[Json] raise DecodeFailure {
  match value {
    Array(value) => value
    _ => raise DecodeFailure("expected array")
  }
}

///|
fn strings(value : Json) -> Array[String] raise DecodeFailure {
  items(value).map(item => text(item))
}

///|
fn stage(value : Json) -> ClientBoardStage raise DecodeFailure {
  match text(value) {
    "created" => Created
    "refining" => Refining
    "ready" => Ready
    "running" => Running
    "review" => Review
    "done" => Done
    "suspended" => Suspended
    _ => raise DecodeFailure("unknown task stage")
  }
}

///|
fn priority(value : Json) -> ClientBoardPriority raise DecodeFailure {
  match text(value) {
    "low" => Low
    "normal" => Normal
    "high" => High
    "critical" => Critical
    _ => raise DecodeFailure("unknown task priority")
  }
}

///|
fn kind(value : Json) -> ClientAttemptKind raise DecodeFailure {
  match text(value) {
    "discuss" => Discuss
    "execute" => Execute
    "review" => Review
    _ => raise DecodeFailure("unknown attempt kind")
  }
}

///|
fn status(value : Json) -> ClientAttemptStatus raise DecodeFailure {
  match text(value) {
    "queued" => Queued
    "running" => Running
    "succeeded" => Succeeded
    "failed" => Failed
    "cancelled" => Cancelled
    "interrupted" => Interrupted
    _ => raise DecodeFailure("unknown attempt status")
  }
}

///|
fn review(value : Json) -> ClientReviewDecision? raise DecodeFailure {
  if value is Null {
    return None
  }
  Some(
    match text(value) {
      "pending" => Pending
      "approved" => Approved
      "changes_requested" => ChangesRequested
      _ => raise DecodeFailure("unknown review decision")
    },
  )
}

///|
fn task(value : Json) -> ClientBoardTask raise DecodeFailure {
  let obj = fields(value)
  {
    id: text(required(obj, "id")),
    title: text(required(obj, "title")),
    description: text(required(obj, "description")),
    stage: stage(required(obj, "stage")),
    priority: priority(required(obj, "priority")),
    definition_of_done: strings(required(obj, "definition_of_done")),
    dependencies: strings(required(obj, "dependencies")),
    created_at_ms: integer(required(obj, "created_at_ms")),
    updated_at_ms: integer(required(obj, "updated_at_ms")),
    ready_since_ms: nullable_integer(required(obj, "ready_since_ms")),
  }
}

///|
fn attempt(value : Json) -> ClientAttempt raise DecodeFailure {
  let obj = fields(value)
  {
    id: text(required(obj, "id")),
    task_id: text(required(obj, "task_id")),
    kind: kind(required(obj, "kind")),
    status: status(required(obj, "status")),
    review: review(required(obj, "review")),
    created_at_ms: integer(required(obj, "created_at_ms")),
    started_at_ms: nullable_integer(required(obj, "started_at_ms")),
    finished_at_ms: nullable_integer(required(obj, "finished_at_ms")),
    updated_at_ms: integer(required(obj, "updated_at_ms")),
  }
}

///|
fn snapshot(
  frame : @protocol.BoardSnapshot,
) -> DecodedBoardSnapshot raise DecodeFailure {
  guard safe_integer(frame.last_seq) && safe_integer(frame.board_revision) else {
    raise DecodeFailure("invalid snapshot counters")
  }
  let payload = fields(frame.payload)
  let board = fields(required(payload, "board"))
  let revision = integer(required(board, "revision"))
  guard revision == frame.board_revision else {
    raise DecodeFailure("snapshot revision mismatch")
  }
  let tasks = items(required(board, "tasks")).map(value => task(value))
  let attempts = items(required(board, "attempts")).map(value => attempt(value))
  let events = items(required(payload, "events"))
  let count = events.length().to_int64()
  guard count <= frame.last_seq && (count != 0L || frame.last_seq == 0L) else {
    raise DecodeFailure("invalid snapshot suffix length")
  }
  for i, value in events {
    match @protocol.decode_server_frame(value.stringify()) {
      Ok(Event(event)) if event.seq ==
        frame.last_seq - count + 1L + i.to_int64() => ()
      _ => raise DecodeFailure("invalid snapshot event suffix")
    }
  }
  { revision, last_seq: frame.last_seq, tasks, attempts, }
}

///|
/// Strictly decode a composite snapshot without retaining any input arrays.
/// The suffix must be contiguous Event frames ending at last_seq. It is
/// transport history, not a second source of projection state.
/// A checked example is in `client.mbt.md`.
pub fn decode_board_snapshot(
  frame : @protocol.BoardSnapshot,
) -> Result[DecodedBoardSnapshot, ClientError] {
  if frame.protocol_version != @protocol.protocol_version() {
    return Err(UnsupportedProtocolVersion)
  }
  Ok(snapshot(frame)) catch {
    DecodeFailure(reason) => Err(InvalidData(reason))
  }
}

///|
priv enum EntityUpdate {
  Task(ClientBoardTask)
  Attempt(ClientAttempt)
}

///|
fn event_entity(
  event : @protocol.BoardWireEvent,
) -> EntityUpdate raise DecodeFailure {
  let obj = fields(event.payload)
  match event.kind {
    "board.task.created"
    | "board.task.updated"
    | "board.task.dependencies_changed"
    | "board.task.stage_changed" => {
      let entity = task(required(obj, "task"))
      guard text(required(obj, "task_id")) == entity.id else {
        raise DecodeFailure("task metadata mismatch")
      }
      Task(entity)
    }
    "board.attempt.queued"
    | "board.attempt.started"
    | "board.attempt.finished"
    | "board.review.recorded" => {
      let entity = attempt(required(obj, "attempt"))
      guard text(required(obj, "attempt_id")) == entity.id &&
        text(required(obj, "task_id")) == entity.task_id else {
        raise DecodeFailure("attempt metadata mismatch")
      }
      Attempt(entity)
    }
    _ => raise DecodeFailure("unknown board event")
  }
}
