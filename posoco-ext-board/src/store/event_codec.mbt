///|
fn event_json(event : @domain.BoardEvent) -> Json {
  let f : Map[String, Json] = { "schema_version": Json::number(1) }
  match event {
    TaskCreated(id~, at_ms~) => {
      f["type"] = "TaskCreated"
      f["id"] = Json::string(id.value)
      f["at_ms"] = number(at_ms)
    }
    TaskUpdated(id~, at_ms~) => {
      f["type"] = "TaskUpdated"
      f["id"] = Json::string(id.value)
      f["at_ms"] = number(at_ms)
    }
    DependenciesSet(id~, dependencies~, at_ms~) => {
      f["type"] = "DependenciesSet"
      f["id"] = Json::string(id.value)
      f["dependencies"] = ids_json(dependencies)
      f["at_ms"] = number(at_ms)
    }
    TaskStageChanged(id~, from~, to~, at_ms~) => {
      f["type"] = "TaskStageChanged"
      f["id"] = Json::string(id.value)
      f["from"] = stage_json(from)
      f["to"] = stage_json(to)
      f["at_ms"] = number(at_ms)
    }
    AttemptQueued(id~, task_id~, kind~, at_ms~) => {
      f["type"] = "AttemptQueued"
      f["id"] = Json::string(id.value)
      f["task_id"] = Json::string(task_id.value)
      f["kind"] = kind_json(kind)
      f["at_ms"] = number(at_ms)
    }
    AttemptStarted(id~, task_id~, at_ms~) => {
      f["type"] = "AttemptStarted"
      f["id"] = Json::string(id.value)
      f["task_id"] = Json::string(task_id.value)
      f["at_ms"] = number(at_ms)
    }
    AttemptFinished(id~, task_id~, outcome~, at_ms~) => {
      f["type"] = "AttemptFinished"
      f["id"] = Json::string(id.value)
      f["task_id"] = Json::string(task_id.value)
      f["outcome"] = outcome_json(outcome)
      f["at_ms"] = number(at_ms)
    }
    ReviewRecorded(id~, task_id~, decision~, at_ms~) => {
      f["type"] = "ReviewRecorded"
      f["id"] = Json::string(id.value)
      f["task_id"] = Json::string(task_id.value)
      f["decision"] = decision_json(decision)
      f["at_ms"] = number(at_ms)
    }
  }
  Json::object(f)
}

///|
fn event_decode(value : Json) -> @domain.BoardEvent raise CodecError {
  let object = match value {
    Json::Object(f) => f
    _ => raise Bad("expected event object")
  }
  let tag = match object.get("type") {
    Some(value) => text(value)
    None => raise Bad("missing event type")
  }
  let keys = ["schema_version", "type", "id", "at_ms"]
  match tag {
    "TaskCreated" | "TaskUpdated" => ()
    "DependenciesSet" => keys.push("dependencies")
    "TaskStageChanged" => {
      keys.push("from")
      keys.push("to")
    }
    "AttemptQueued" => {
      keys.push("task_id")
      keys.push("kind")
    }
    "AttemptStarted" => keys.push("task_id")
    "AttemptFinished" => {
      keys.push("task_id")
      keys.push("outcome")
    }
    "ReviewRecorded" => {
      keys.push("task_id")
      keys.push("decision")
    }
    _ => raise Bad("unknown domain event type")
  }
  let f = fields(value, keys)
  version(f)
  let at_ms = integer(f["at_ms"])
  match tag {
    "TaskCreated" => TaskCreated(id=task_id(f["id"]), at_ms~)
    "TaskUpdated" => TaskUpdated(id=task_id(f["id"]), at_ms~)
    "DependenciesSet" =>
      DependenciesSet(
        id=task_id(f["id"]),
        dependencies=ids(f["dependencies"]),
        at_ms~,
      )
    "TaskStageChanged" =>
      TaskStageChanged(
        id=task_id(f["id"]),
        from=stage(f["from"]),
        to=stage(f["to"]),
        at_ms~,
      )
    "AttemptQueued" =>
      AttemptQueued(
        id=attempt_id(f["id"]),
        task_id=task_id(f["task_id"]),
        kind=kind(f["kind"]),
        at_ms~,
      )
    "AttemptStarted" =>
      AttemptStarted(
        id=attempt_id(f["id"]),
        task_id=task_id(f["task_id"]),
        at_ms~,
      )
    "AttemptFinished" =>
      AttemptFinished(
        id=attempt_id(f["id"]),
        task_id=task_id(f["task_id"]),
        outcome=outcome(f["outcome"]),
        at_ms~,
      )
    "ReviewRecorded" =>
      ReviewRecorded(
        id=attempt_id(f["id"]),
        task_id=task_id(f["task_id"]),
        decision=decision(f["decision"]),
        at_ms~,
      )
    _ => raise Bad("unknown domain event type")
  }
}

///|
pub fn encode_event(
  event : @domain.BoardEvent,
) -> Result[String, BoardStoreError] {
  let value = event_json(event)
  try {
    let _ = event_decode(value)
    Ok(value.stringify())
  } catch {
    Bad(message) => Err(InvalidData(message))
  }
}

///|
pub fn decode_event(
  input : String,
) -> Result[@domain.BoardEvent, BoardStoreError] {
  Ok(event_decode(strict_json(input))) catch {
    Bad(message) => Err(InvalidData(message))
    error => Err(InvalidData(error.to_string()))
  }
}

///|
fn journal_record_json(record : JournalRecord) -> Json {
  let f = match event_json(record.event) {
    Json::Object(f) => f
    _ => abort("event object")
  }
  f["schema_version"] = Json::number(record.schema_version.to_double())
  f["revision"] = number(record.revision)
  Json::object(f)
}

///|
pub fn encode_journal_record(
  record : JournalRecord,
) -> Result[String, BoardStoreError] {
  decode_journal_record(journal_record_json(record).stringify()).map(_ => {
    journal_record_json(record).stringify()
  })
}

///|
pub fn decode_journal_record(
  input : String,
) -> Result[JournalRecord, BoardStoreError] {
  try {
    let f = match strict_json(input) {
      Json::Object(f) => f
      _ => raise Bad("expected journal object")
    }
    version(f)
    let revision = match f.get("revision") {
      Some(value) => integer(value)
      None => raise Bad("missing journal revision")
    }
    let _ = f.remove("revision")
    let event = event_decode(Json::object(f))
    Ok({ schema_version: 1, revision, event, })
  } catch {
    Bad(message) => Err(InvalidData(message))
    error => Err(InvalidData(error.to_string()))
  }
}

///|
// Append metadata is consumed only by the native filesystem store.
#warnings("-unused_field")
priv struct JournalScan {
  journal : Array[JournalRecord]
  retained : String
  add_newline : Bool
}

///|
/// Ignore only syntactically malformed unterminated JSON, not a complete
/// JSON value with an invalid schema, duplicate fields or unknown event.
fn scan_journal(input : String) -> Result[JournalScan, BoardStoreError] {
  let journal : Array[JournalRecord] = []
  let mut start = 0
  for i = 0; i < input.length(); i = i + 1 {
    if input[i] == '\n' {
      match decode_journal_record(input[start:i].to_owned()) {
        Ok(record) => journal.push(record)
        Err(error) => return Err(error)
      }
      start = i + 1
    }
  }
  if start < input.length() {
    let tail = input[start:].to_owned()
    let syntax_valid = try {
      let _ = @json.parse(tail)
      true
    } catch {
      _ => false
    }
    if !syntax_valid {
      return Ok({
        journal,
        retained: input[:start].to_owned(),
        add_newline: false,
      })
    }
    match decode_journal_record(tail) {
      Ok(record) => {
        journal.push(record)
        return Ok({ journal, retained: input, add_newline: true, })
      }
      Err(error) => return Err(error)
    }
  }
  Ok({ journal, retained: input, add_newline: false, })
}

///|
pub fn decode_journal(
  input : String,
) -> Result[Array[JournalRecord], BoardStoreError] {
  scan_journal(input).map(scan => scan.journal)
}
