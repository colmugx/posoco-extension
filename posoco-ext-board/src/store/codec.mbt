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
      Cancelled => "Cancelled"
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
    "Cancelled" => Cancelled
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
fn optional_fields(
  value : Json,
  required : Array[String],
  optional : Array[String],
) -> Map[String, Json] raise CodecError {
  let object = match value {
    Json::Object(object) => object
    _ => raise Bad("expected object")
  }
  for key in required {
    if !object.contains(key) {
      bad("missing field '\{key}'")
    }
  }
  for key in object.keys() {
    if !required.contains(key) && !optional.contains(key) {
      bad("unexpected field '\{key}'")
    }
  }
  object
}

///|
fn model_json(value : @domain.ModelSelection?) -> Json {
  match value {
    Some(model) =>
      Json::object({
        "slot": Json::string(model.slot),
        "effort": match model.effort {
          Some(effort) => Json::string(effort)
          None => Json::null()
        },
      })
    None => Json::null()
  }
}

///|
fn model(value : Json) -> @domain.ModelSelection? raise CodecError {
  match value {
    Json::Null => None
    Json::Object(object) => {
      for key in object.keys() {
        if key != "slot" && key != "effort" {
          bad("unexpected model field '\{key}'")
        }
      }
      let slot = match object.get("slot") {
        Some(value) => nonempty(value)
        None => raise Bad("model is missing slot")
      }
      let effort = match object.get("effort") {
        Some(Json::Null) | None => None
        Some(value) => Some(nonempty(value))
      }
      Some(@domain.ModelSelection::ModelSelection(slot~, effort~))
    }
    _ => raise Bad("expected model object or null")
  }
}

///|
fn evidence_kind_json(value : @domain.ReviewEvidenceKind) -> Json {
  Json::string(
    match value {
      Command => "Command"
      Test => "Test"
      Manual => "Manual"
      Artifact => "Artifact"
    },
  )
}

///|
fn evidence_kind(value : Json) -> @domain.ReviewEvidenceKind raise CodecError {
  match text(value) {
    "Command" => Command
    "Test" => Test
    "Manual" => Manual
    "Artifact" => Artifact
    _ => raise Bad("unknown review evidence kind")
  }
}

///|
fn evidence_result_json(value : @domain.ReviewEvidenceResult) -> Json {
  Json::string(
    match value {
      Passed => "Passed"
      Failed => "Failed"
      NotRun => "NotRun"
      Unknown => "Unknown"
    },
  )
}

///|
fn evidence_result(
  value : Json,
) -> @domain.ReviewEvidenceResult raise CodecError {
  match text(value) {
    "Passed" => Passed
    "Failed" => Failed
    "NotRun" => NotRun
    "Unknown" => Unknown
    _ => raise Bad("unknown review evidence result")
  }
}

///|
fn artifact_kind_json(value : @domain.ReviewArtifactKind) -> Json {
  Json::string(
    match value {
      File => "File"
      Diff => "Diff"
      Log => "Log"
      Screenshot => "Screenshot"
      Url => "Url"
    },
  )
}

///|
fn artifact_kind(value : Json) -> @domain.ReviewArtifactKind raise CodecError {
  match text(value) {
    "File" => File
    "Diff" => Diff
    "Log" => Log
    "Screenshot" => Screenshot
    "Url" => Url
    _ => raise Bad("unknown review artifact kind")
  }
}

///|
fn strings_json(values : Array[String]) -> Json {
  Json::array(values.map(Json::string))
}

///|
fn strings(value : Json) -> Array[String] raise CodecError {
  array(value).map(text)
}

///|
/// Review evidence keeps free-form label/detail text; the identifiers and
/// enum names are the only strictly validated parts.
fn evidence_json(evidence : @domain.ReviewEvidence) -> Json {
  Json::object({
    "kind": evidence_kind_json(evidence.kind),
    "label": Json::string(evidence.label),
    "result": evidence_result_json(evidence.result),
    "detail": Json::string(evidence.detail),
  })
}

///|
fn evidence_decode(value : Json) -> @domain.ReviewEvidence raise CodecError {
  let f = fields(value, ["kind", "label", "result", "detail"])
  @domain.ReviewEvidence::from_record(
    kind=evidence_kind(f["kind"]),
    label=nonempty(f["label"]),
    result=evidence_result(f["result"]),
    detail=text(f["detail"]),
  )
}

///|
fn artifact_json(artifact : @domain.ReviewArtifact) -> Json {
  Json::object({
    "kind": artifact_kind_json(artifact.kind),
    "label": Json::string(artifact.label),
    "uri_or_digest": Json::string(artifact.uri_or_digest),
  })
}

///|
fn artifact_decode(value : Json) -> @domain.ReviewArtifact raise CodecError {
  let f = fields(value, ["kind", "label", "uri_or_digest"])
  @domain.ReviewArtifact::from_record(
    kind=artifact_kind(f["kind"]),
    label=nonempty(f["label"]),
    uri_or_digest=nonempty(f["uri_or_digest"]),
  )
}

///|
/// The report is durable data, not activity: only the curated fields are
/// persisted, each ordered exactly as the writer produced it.
fn review_json(report : @domain.ReviewReport?) -> Json {
  match report {
    Some(report) =>
      Json::object({
        "outcome": Json::string(report.outcome),
        "summary": Json::string(report.summary),
        "changes": strings_json(report.changes),
        "verification": Json::array(report.verification.map(evidence_json)),
        "risks": strings_json(report.risks),
        "notes": strings_json(report.notes),
        "open_questions": strings_json(report.open_questions),
        "artifacts": Json::array(report.artifacts.map(artifact_json)),
      })
    None => Json::null()
  }
}

///|
fn review(value : Json) -> @domain.ReviewReport? raise CodecError {
  match value {
    Json::Null => None
    Json::Object(_) => {
      let f = fields(value, [
        "outcome", "summary", "changes", "verification", "risks", "notes", "open_questions",
        "artifacts",
      ])
      Some(
        @domain.ReviewReport::from_record(
          outcome=nonempty(f["outcome"]),
          summary=text(f["summary"]),
          changes=strings(f["changes"]),
          verification=array(f["verification"]).map(evidence_decode),
          risks=strings(f["risks"]),
          notes=strings(f["notes"]),
          open_questions=strings(f["open_questions"]),
          artifacts=array(f["artifacts"]).map(artifact_decode),
        ),
      )
    }
    _ => raise Bad("expected review object or null")
  }
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
    "model": model_json(task.model),
    "review": review_json(task.review),
    "review_feedback": match task.review_feedback {
      Some(value) => Json::string(value)
      None => Json::null()
    },
  })
}

///|
/// `model`, `review` and `review_feedback` are optional keys so every
/// pre-existing store keeps decoding with them absent.
fn task_decode(value : Json) -> @domain.BoardTask raise CodecError {
  let f = optional_fields(
    value,
    [
      "id", "title", "description", "stage", "priority", "definition_of_done", "dependencies",
      "created_at_ms", "updated_at_ms", "ready_since_ms",
    ],
    ["model", "review", "review_feedback"],
  )
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
    model=match f.get("model") {
      Some(value) => model(value)
      None => None
    },
    review=match f.get("review") {
      Some(value) => review(value)
      None => None
    },
    review_feedback=match f.get("review_feedback") {
      Some(Json::Null) | None => None
      Some(value) => Some(nonempty(value))
    },
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
/// Durable S4E1 expansion record: identity, lineage, local_ref mapping and
/// the normalized content binding. Only digests and identifiers are
/// persisted — never raw proposal text.
fn mapping_json(mapping : Array[@domain.ExpansionMapping]) -> Json {
  Json::array(
    mapping.map(entry => {
      Json::object({
        "local_ref": Json::string(entry.local_ref),
        "task_id": Json::string(entry.task_id.value),
      })
    }),
  )
}

///|
fn mapping_decode(
  value : Json,
) -> Array[@domain.ExpansionMapping] raise CodecError {
  array(value).map(value => {
    let f = fields(value, ["local_ref", "task_id"])
    { local_ref: nonempty(f["local_ref"]), task_id: task_id(f["task_id"]), }
  })
}

///|
fn expansion_json(record : @domain.ExpansionRecord) -> Json {
  Json::object({
    "expansion_id": Json::string(record.expansion_id.value),
    "parent_task_id": Json::string(record.parent_task_id.value),
    "workflow_id": Json::string(record.workflow_id),
    "mapping": mapping_json(record.mapping),
    "content_digest": Json::string(record.content_digest),
    "created_at_ms": number(record.created_at_ms),
  })
}

///|
fn expansion_decode(value : Json) -> @domain.ExpansionRecord raise CodecError {
  let f = fields(value, [
    "expansion_id", "parent_task_id", "workflow_id", "mapping", "content_digest",
    "created_at_ms",
  ])
  @domain.ExpansionRecord::from_record(
    expansion_id=@domain.ExpansionId(nonempty(f["expansion_id"])),
    parent_task_id=task_id(f["parent_task_id"]),
    workflow_id=nonempty(f["workflow_id"]),
    mapping=mapping_decode(f["mapping"]),
    content_digest=nonempty(f["content_digest"]),
    created_at_ms=integer(f["created_at_ms"]),
  )
}

///|
fn expansions_json(expansions : Array[@domain.ExpansionRecord]) -> Json {
  Json::array(expansions.map(expansion_json))
}

///|
/// Snapshot schema v2 adds the durable expansion history. v1 boards carry
/// no expansions key and decode with an empty history, so every pre-S4E1
/// snapshot keeps loading unchanged.
fn snapshot_json(snapshot : @domain.BoardStateSnapshot) -> Json {
  Json::object({
    "schema_version": Json::number(2),
    "revision": number(snapshot.revision),
    "tasks": Json::array(snapshot.tasks.map(task_json)),
    "attempts": Json::array(snapshot.attempts.map(attempt_json)),
    "expansions": expansions_json(snapshot.expansions),
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
fn snapshot_version(value : Json) -> Int64 raise CodecError {
  let mut schema = 0L
  match value {
    Json::Number(1, ..) => schema = 1L
    Json::Number(2, ..) => schema = 2L
    _ => bad("unsupported schema version")
  }
  schema
}

///|
/// v1 boards (pre-S4E1) carry exactly the four historical keys and decode
/// with an empty expansion history; v2 boards carry the durable expansion
/// history. Any other shape is rejected.
fn snapshot_decode(value : Json) -> @domain.BoardStateSnapshot raise CodecError {
  let object = match value {
    Json::Object(object) => object
    _ => raise Bad("expected object")
  }
  let schema = match object.get("schema_version") {
    Some(value) => snapshot_version(value)
    None => raise Bad("missing field 'schema_version'")
  }
  if schema == 1L && object.contains("expansions") {
    bad("unexpected field 'expansions' for schema version 1")
  }
  let keys = if schema == 1L {
    ["schema_version", "revision", "tasks", "attempts"]
  } else {
    ["schema_version", "revision", "tasks", "attempts", "expansions"]
  }
  let f = fields(value, keys)
  let expansions : Array[@domain.ExpansionRecord] = if schema == 1L {
    []
  } else {
    array(f["expansions"]).map(expansion_decode)
  }
  let snapshot : @domain.BoardStateSnapshot = {
    revision: integer(f["revision"]),
    tasks: array(f["tasks"]).map(task_decode),
    attempts: array(f["attempts"]).map(attempt_decode),
    expansions,
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
  let colors : Map[String, Int32] = Map::from_array([])
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
  // The domain is the single authority for durable expansion identity rules.
  match @domain.BoardState::from_snapshot(snapshot) {
    Err(_) => bad("invalid snapshot identity")
    Ok(_) => ()
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
