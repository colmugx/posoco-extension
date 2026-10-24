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
    TaskModelChanged(id~, model~, at_ms~) => {
      f["type"] = "TaskModelChanged"
      f["id"] = Json::string(id.value)
      f["model"] = model_json(model)
      f["at_ms"] = number(at_ms)
    }
    ReviewReportSet(id~, review~, at_ms~) => {
      f["type"] = "ReviewReportSet"
      f["id"] = Json::string(id.value)
      f["review"] = review_json(review)
      f["at_ms"] = number(at_ms)
    }
    TaskStageChanged(id~, from~, to~, at_ms~) => {
      f["type"] = "TaskStageChanged"
      f["id"] = Json::string(id.value)
      f["from"] = stage_json(from)
      f["to"] = stage_json(to)
      f["at_ms"] = number(at_ms)
    }
    TaskDeleted(id~, at_ms~) => {
      f["type"] = "TaskDeleted"
      f["id"] = Json::string(id.value)
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
    GraphExpanded(
      expansion~,
      tasks~,
      parent~,
      workflow~,
      mapping~,
      digest~,
      at_ms~
    ) => {
      f["type"] = "GraphExpanded"
      f["expansion_id"] = Json::string(expansion.value)
      f["tasks"] = Json::array(tasks.map(task_json))
      f["parent_task_id"] = Json::string(parent.value)
      f["workflow_id"] = Json::string(workflow)
      f["mapping"] = mapping_json(mapping)
      f["content_digest"] = Json::string(digest)
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
  let keys = ["schema_version", "type", "at_ms"]
  match tag {
    "TaskCreated" | "TaskUpdated" | "TaskDeleted" => keys.push("id")
    "DependenciesSet" => {
      keys.push("id")
      keys.push("dependencies")
    }
    "TaskModelChanged" => {
      keys.push("id")
      keys.push("model")
    }
    "ReviewReportSet" => {
      keys.push("id")
      keys.push("review")
    }
    "TaskStageChanged" => {
      keys.push("id")
      keys.push("from")
      keys.push("to")
    }
    "AttemptQueued" => {
      keys.push("id")
      keys.push("task_id")
      keys.push("kind")
    }
    "AttemptStarted" => {
      keys.push("id")
      keys.push("task_id")
    }
    "AttemptFinished" => {
      keys.push("id")
      keys.push("task_id")
      keys.push("outcome")
    }
    "ReviewRecorded" => {
      keys.push("id")
      keys.push("task_id")
      keys.push("decision")
    }
    "GraphExpanded" => {
      keys.push("expansion_id")
      keys.push("tasks")
      keys.push("parent_task_id")
      keys.push("workflow_id")
      keys.push("mapping")
      keys.push("content_digest")
    }
    _ => raise Bad("unknown domain event type")
  }
  let f = fields(value, keys)
  version(f)
  let at_ms = integer(f["at_ms"])
  match tag {
    "TaskCreated" => TaskCreated(id=task_id(f["id"]), at_ms~)
    "TaskUpdated" => TaskUpdated(id=task_id(f["id"]), at_ms~)
    "TaskDeleted" => TaskDeleted(id=task_id(f["id"]), at_ms~)
    "DependenciesSet" =>
      DependenciesSet(
        id=task_id(f["id"]),
        dependencies=ids(f["dependencies"]),
        at_ms~,
      )
    "TaskModelChanged" =>
      TaskModelChanged(id=task_id(f["id"]), model=model(f["model"]), at_ms~)
    "ReviewReportSet" =>
      ReviewReportSet(id=task_id(f["id"]), review=review(f["review"]), at_ms~)
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
    "GraphExpanded" => {
      let tasks = array(f["tasks"]).map(task_decode)
      let mapping = mapping_decode(f["mapping"])
      let digest = nonempty(f["content_digest"])
      let expansion = @domain.ExpansionId(nonempty(f["expansion_id"]))
      let parent = task_id(f["parent_task_id"])
      let workflow = nonempty(f["workflow_id"])
      // Validate the complete normalized event, not just individual entities.
      if !@domain.valid_expansion_digest(digest) ||
        tasks.is_empty() ||
        mapping.length() != tasks.length() ||
        workflow.trim().is_empty() ||
        expansion.value.trim().is_empty() {
        bad("invalid expansion event identity")
      }
      let ids : Set[@domain.BoardTaskId] = Set::from_array([])
      let refs : Set[String] = Set::from_array([])
      let candidates : Array[@domain.GraphTask] = []
      for i, task in tasks {
        let entry = mapping[i]
        if task.id != entry.task_id ||
          ids.contains(task.id) ||
          refs.contains(entry.local_ref) ||
          entry.local_ref.trim().is_empty() ||
          task.id == parent ||
          task.stage != @domain.Created ||
          task.created_at_ms != at_ms ||
          task.updated_at_ms != at_ms ||
          task.ready_since_ms != None {
          bad("invalid expansion task mapping")
        }
        ids.add(task.id)
        refs.add(entry.local_ref)
        candidates.push(
          @domain.GraphTask::from_record(
            id=task.id,
            title=task.title,
            description=task.description,
            priority=task.priority,
            definition_of_done=task.definition_of_done,
            dependencies=task.dependencies,
            local_ref=entry.local_ref,
          ),
        )
      }
      if @domain.expansion_content_digest(
          expansion~,
          candidates~,
          parent~,
          workflow~,
        ) !=
        digest {
        bad("expansion digest mismatch")
      }
      GraphExpanded(
        expansion~,
        tasks~,
        parent~,
        workflow~,
        mapping~,
        digest~,
        at_ms~,
      )
    }
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
