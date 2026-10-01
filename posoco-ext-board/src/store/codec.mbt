///|
priv suberror CodecError {
  Bad(String)
}

///|
fn bad(message : String) -> Unit raise CodecError {
  raise Bad(message)
}

///|
fn fields(
  value : Json,
  keys : Array[String],
) -> Map[String, Json] raise CodecError {
  let object = match value {
    Json::Object(object) => object
    _ => raise Bad("expected object")
  }
  if object.length() != keys.length() {
    bad("unexpected or missing fields")
  }
  for key in keys {
    if !object.contains(key) {
      bad("missing field '\{key}'")
    }
  }
  object
}

///|
fn text(value : Json) -> String raise CodecError {
  match value {
    Json::String(value) => value
    _ => raise Bad("expected string")
  }
}

///|
fn nonempty(value : Json) -> String raise CodecError {
  let value = text(value)
  if value.is_empty() {
    bad("empty identifier or text")
  }
  value
}

///|
fn array(value : Json) -> Array[Json] raise CodecError {
  match value {
    Json::Array(values) => values
    _ => raise Bad("expected array")
  }
}

///|
/// Canonical decimal strings preserve every Int64 bit on both targets.
fn integer(value : Json) -> Int64 raise CodecError {
  let value = text(value)
  if value.is_empty() || (value.length() > 1 && value[0] == '0') {
    raise Bad("expected canonical nonnegative Int64")
  }
  let mut result = 0L
  for ch in value {
    if ch < '0' || ch > '9' {
      bad("invalid decimal integer")
    }
    let digit = (ch.to_int() - 48).to_int64()
    if result > (9223372036854775807L - digit) / 10L {
      bad("Int64 overflow")
    }
    result = result * 10L + digit
  }
  result
}

///|
fn optional_integer(value : Json) -> Int64? raise CodecError {
  match value {
    Json::Null => None
    _ => Some(integer(value))
  }
}

///|
fn number(value : Int64) -> Json {
  Json::string(value.to_string())
}

///|
fn optional_number(value : Int64?) -> Json {
  match value {
    Some(value) => number(value)
    None => Json::null()
  }
}

///|
fn stage_json(value : @domain.BoardStage) -> Json {
  Json::string(
    match value {
      Created => "Created"
      Refining => "Refining"
      Ready => "Ready"
      Running => "Running"
      Review => "Review"
      Done => "Done"
      Suspended => "Suspended"
    },
  )
}

///|
fn stage(value : Json) -> @domain.BoardStage raise CodecError {
  match text(value) {
    "Created" => Created
    "Refining" => Refining
    "Ready" => Ready
    "Running" => Running
    "Review" => Review
    "Done" => Done
    "Suspended" => Suspended
    _ => raise Bad("unknown task stage")
  }
}

///|
fn priority_json(value : @domain.BoardPriority) -> Json {
  Json::string(
    match value {
      Low => "Low"
      Normal => "Normal"
      High => "High"
      Critical => "Critical"
    },
  )
}

///|
fn priority(value : Json) -> @domain.BoardPriority raise CodecError {
  match text(value) {
    "Low" => Low
    "Normal" => Normal
    "High" => High
    "Critical" => Critical
    _ => raise Bad("unknown priority")
  }
}

///|
fn kind_json(value : @domain.AttemptKind) -> Json {
  Json::string(
    match value {
      Discuss => "Discuss"
      Execute => "Execute"
      Review => "Review"
    },
  )
}

///|
fn kind(value : Json) -> @domain.AttemptKind raise CodecError {
  match text(value) {
    "Discuss" => Discuss
    "Execute" => Execute
    "Review" => Review
    _ => raise Bad("unknown attempt kind")
  }
}

///|
fn status_json(value : @domain.AttemptStatus) -> Json {
  Json::string(
    match value {
      Queued => "Queued"
      Running => "Running"
      Succeeded => "Succeeded"
      Failed => "Failed"
      Cancelled => "Cancelled"
      Interrupted => "Interrupted"
    },
  )
}

///|
fn status(value : Json) -> @domain.AttemptStatus raise CodecError {
  match text(value) {
    "Queued" => Queued
    "Running" => Running
    "Succeeded" => Succeeded
    "Failed" => Failed
    "Cancelled" => Cancelled
    "Interrupted" => Interrupted
    _ => raise Bad("unknown attempt status")
  }
}

///|
fn outcome_json(value : @domain.AttemptOutcome) -> Json {
  Json::string(
    match value {
      Succeeded => "Succeeded"
      Failed => "Failed"
      Cancelled => "Cancelled"
      Interrupted => "Interrupted"
    },
  )
}

///|
fn outcome(value : Json) -> @domain.AttemptOutcome raise CodecError {
  match text(value) {
    "Succeeded" => Succeeded
    "Failed" => Failed
    "Cancelled" => Cancelled
    "Interrupted" => Interrupted
    _ => raise Bad("unknown attempt outcome")
  }
}

///|
fn decision_json(value : @domain.ReviewDecision) -> Json {
  Json::string(
    match value {
      Pending => "Pending"
      Approved => "Approved"
      ChangesRequested => "ChangesRequested"
    },
  )
}

///|
fn decision(value : Json) -> @domain.ReviewDecision raise CodecError {
  match text(value) {
    "Pending" => Pending
    "Approved" => Approved
    "ChangesRequested" => ChangesRequested
    _ => raise Bad("unknown review decision")
  }
}

///|
fn task_id(value : Json) -> @domain.BoardTaskId raise CodecError {
  @domain.BoardTaskId::BoardTaskId(nonempty(value))
}

///|
fn attempt_id(value : Json) -> @domain.AttemptId raise CodecError {
  @domain.AttemptId::AttemptId(nonempty(value))
}

///|
fn ids(value : Json) -> Array[@domain.BoardTaskId] raise CodecError {
  array(value).map(task_id)
}

///|
fn ids_json(value : Array[@domain.BoardTaskId]) -> Json {
  Json::array(value.map(id => Json::string(id.value)))
}

///|
fn task_json(task : @domain.BoardTask) -> Json {
  Json::object({
    "id": Json::string(task.id.value),
    "title": Json::string(task.title),
    "description": Json::string(task.description),
    "stage": stage_json(task.stage),
    "priority": priority_json(task.priority),
    "definition_of_done": Json::array(task.definition_of_done.map(Json::string)),
    "dependencies": ids_json(task.dependencies),
    "created_at_ms": number(task.created_at_ms),
    "updated_at_ms": number(task.updated_at_ms),
    "ready_since_ms": optional_number(task.ready_since_ms),
  })
}

///|
fn task_decode(value : Json) -> @domain.BoardTask raise CodecError {
  let f = fields(value, [
    "id", "title", "description", "stage", "priority", "definition_of_done", "dependencies",
    "created_at_ms", "updated_at_ms", "ready_since_ms",
  ])
  @domain.BoardTask::from_record(
    id=task_id(f["id"]),
    title=nonempty(f["title"]),
    description=text(f["description"]),
    stage=stage(f["stage"]),
    priority=priority(f["priority"]),
    definition_of_done=array(f["definition_of_done"]).map(nonempty),
    dependencies=ids(f["dependencies"]),
    created_at_ms=integer(f["created_at_ms"]),
    updated_at_ms=integer(f["updated_at_ms"]),
    ready_since_ms=optional_integer(f["ready_since_ms"]),
  )
}

///|
fn attempt_json(attempt : @domain.Attempt) -> Json {
  Json::object({
    "id": Json::string(attempt.id.value),
    "task_id": Json::string(attempt.task_id.value),
    "kind": kind_json(attempt.kind),
    "status": status_json(attempt.status),
    "review": match attempt.review {
      Some(value) => decision_json(value)
      None => Json::null()
    },
    "created_at_ms": number(attempt.created_at_ms),
    "started_at_ms": optional_number(attempt.started_at_ms),
    "finished_at_ms": optional_number(attempt.finished_at_ms),
    "updated_at_ms": number(attempt.updated_at_ms),
  })
}

///|
fn attempt_decode(value : Json) -> @domain.Attempt raise CodecError {
  let f = fields(value, [
    "id", "task_id", "kind", "status", "review", "created_at_ms", "started_at_ms",
    "finished_at_ms", "updated_at_ms",
  ])
  @domain.Attempt::from_record(
    id=attempt_id(f["id"]),
    task_id=task_id(f["task_id"]),
    kind=kind(f["kind"]),
    status=status(f["status"]),
    review=match f["review"] {
      Json::Null => None
      value => Some(decision(value))
    },
    created_at_ms=integer(f["created_at_ms"]),
    started_at_ms=optional_integer(f["started_at_ms"]),
    finished_at_ms=optional_integer(f["finished_at_ms"]),
    updated_at_ms=integer(f["updated_at_ms"]),
  )
}

///|
fn snapshot_json(snapshot : @domain.BoardStateSnapshot) -> Json {
  Json::object({
    "schema_version": Json::number(1),
    "revision": number(snapshot.revision),
    "tasks": Json::array(snapshot.tasks.map(task_json)),
    "attempts": Json::array(snapshot.attempts.map(attempt_json)),
  })
}

///|
fn version(f : Map[String, Json]) -> Unit raise CodecError {
  match f.get("schema_version") {
    Some(Json::Number(1, ..)) => ()
    _ => bad("unsupported schema version")
  }
}

///|
fn snapshot_decode(value : Json) -> @domain.BoardStateSnapshot raise CodecError {
  let f = fields(value, ["schema_version", "revision", "tasks", "attempts"])
  version(f)
  let snapshot : @domain.BoardStateSnapshot = {
    revision: integer(f["revision"]),
    tasks: array(f["tasks"]).map(task_decode),
    attempts: array(f["attempts"]).map(attempt_decode),
  }
  validate_references(snapshot)
  snapshot
}

///|
/// Validate identity and graph integrity, not S4 execution coupling or
/// timestamp monotonicity (the domain accepts explicit nonnegative times).
fn validate_references(
  snapshot : @domain.BoardStateSnapshot,
) -> Unit raise CodecError {
  let tasks : Map[String, @domain.BoardTask] = Map::from_array([])
  for task in snapshot.tasks {
    if tasks.contains(task.id.value) {
      bad("duplicate task id")
    }
    tasks[task.id.value] = task
  }
  for task in snapshot.tasks {
    let seen : Map[String, Bool] = Map::from_array([])
    for dep in task.dependencies {
      if !tasks.contains(dep.value) {
        bad("missing dependency")
      }
      if dep == task.id {
        bad("self dependency")
      }
      if seen.contains(dep.value) {
        bad("duplicate dependency")
      }
      seen[dep.value] = true
    }
  }
  let colors : Map[String, Int] = Map::from_array([])
  fn visit(id : String) -> Unit raise CodecError {
    match colors.get(id) {
      Some(1) => bad("dependency cycle")
      Some(2) => return
      _ => ()
    }
    colors[id] = 1
    for dep in tasks[id].dependencies {
      visit(dep.value)
    }
    colors[id] = 2
  }
  for task in snapshot.tasks {
    visit(task.id.value)
  }
  let attempts : Map[String, Bool] = Map::from_array([])
  for attempt in snapshot.attempts {
    if attempts.contains(attempt.id.value) {
      bad("duplicate attempt id")
    }
    if !tasks.contains(attempt.task_id.value) {
      bad("attempt task missing")
    }
    attempts[attempt.id.value] = true
  }
}

///|
pub fn encode_snapshot(
  snapshot : @domain.BoardStateSnapshot,
) -> Result[String, BoardStoreError] {
  let value = snapshot_json(snapshot)
  try {
    let _ = snapshot_decode(value)
    Ok(value.stringify())
  } catch {
    Bad(message) => Err(InvalidData(message))
  }
}

///|
pub fn decode_snapshot(
  input : String,
) -> Result[@domain.BoardStateSnapshot, BoardStoreError] {
  Ok(snapshot_decode(strict_json(input))) catch {
    Bad(message) => Err(InvalidData(message))
    error => Err(InvalidData(error.to_string()))
  }
}
