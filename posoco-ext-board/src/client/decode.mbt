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
    "verification" => Verification
    "review" => Review
    "done" => Done
    "suspended" => Suspended
    "cancelled" => Cancelled
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
fn model(value : Json) -> ClientModelSelection? raise DecodeFailure {
  match value {
    Null => None
    Object(obj) => {
      let effort = match obj.get("effort") {
        None | Some(Null) => None
        Some(value) => Some(text(value))
      }
      Some({ slot: text(required(obj, "slot")), effort, })
    }
    _ => raise DecodeFailure("expected model object or null")
  }
}

///|
fn review_evidence_kind(
  value : Json,
) -> ClientReviewEvidenceKind raise DecodeFailure {
  match text(value) {
    "command" => Command
    "test" => Test
    "manual" => Manual
    "artifact" => Artifact
    _ => raise DecodeFailure("unknown review evidence kind")
  }
}

///|
fn review_evidence_result(
  value : Json,
) -> ClientReviewEvidenceResult raise DecodeFailure {
  match text(value) {
    "passed" => Passed
    "failed" => Failed
    "not_run" => NotRun
    "unknown" => Unknown
    _ => raise DecodeFailure("unknown review evidence result")
  }
}

///|
fn review_artifact_kind(
  value : Json,
) -> ClientReviewArtifactKind raise DecodeFailure {
  match text(value) {
    "file" => File
    "diff" => Diff
    "log" => Log
    "screenshot" => Screenshot
    "url" => Url
    _ => raise DecodeFailure("unknown review artifact kind")
  }
}

///|
fn review_evidence(value : Json) -> ClientReviewEvidence raise DecodeFailure {
  let obj = fields(value)
  {
    kind: review_evidence_kind(required(obj, "kind")),
    label: text(required(obj, "label")),
    result: review_evidence_result(required(obj, "result")),
    detail: text(required(obj, "detail")),
  }
}

///|
fn review_artifact(value : Json) -> ClientReviewArtifact raise DecodeFailure {
  let obj = fields(value)
  {
    kind: review_artifact_kind(required(obj, "kind")),
    label: text(required(obj, "label")),
    uri_or_digest: text(required(obj, "uri_or_digest")),
  }
}

///|
fn review_report(value : Json) -> ClientReviewReport raise DecodeFailure {
  let obj = fields(value)
  {
    outcome: text(required(obj, "outcome")),
    summary: text(required(obj, "summary")),
    changes: strings(required(obj, "changes")),
    verification: items(required(obj, "verification")).map(value => {
      review_evidence(value)
    }),
    risks: strings(required(obj, "risks")),
    notes: strings(required(obj, "notes")),
    open_questions: strings(required(obj, "open_questions")),
    artifacts: items(required(obj, "artifacts")).map(value => {
      review_artifact(value)
    }),
  }
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
    user_story: match obj.get("user_story") {
      None => ""
      Some(value) => text(value)
    },
    implementation_suggestions: match obj.get("implementation_suggestions") {
      None => ""
      Some(value) => text(value)
    },
    model: match obj.get("model") {
      Some(value) => model(value)
      None => None
    },
    review: match obj.get("review") {
      None | Some(Null) => None
      Some(value) => Some(review_report(value))
    },
    review_feedback: match obj.get("review_feedback") {
      None | Some(Null) => None
      Some(value) => Some(text(value))
    },
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
  /// One committed fact that changes a ticket and its attempt together.
  TaskAndAttempt(ClientBoardTask, ClientAttempt)
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
    | "board.task.model_changed"
    | "board.task.review_report_set"
    | "board.task.stage_changed" => {
      let entity = task(required(obj, "task"))
      guard text(required(obj, "task_id")) == entity.id else {
        raise DecodeFailure("task metadata mismatch")
      }
      Task(entity)
    }
    "board.task.review_changes_requested" => {
      let entity = task(required(obj, "task"))
      let attempt = attempt(required(obj, "attempt"))
      guard text(required(obj, "task_id")) == entity.id &&
        text(required(obj, "attempt_id")) == attempt.id &&
        attempt.task_id == entity.id &&
        entity.stage == Ready &&
        entity.review_feedback == Some(text(required(obj, "feedback"))) else {
        raise DecodeFailure("request-changes metadata mismatch")
      }
      TaskAndAttempt(entity, attempt)
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

///|
fn graph_entities(
  event : @protocol.BoardWireEvent,
  existing : Array[ClientBoardTask],
) -> Array[ClientBoardTask] raise DecodeFailure {
  let obj = fields(event.payload)
  let expansion = @domain.ExpansionId(text(required(obj, "expansion_id")))
  let parent = @domain.BoardTaskId(text(required(obj, "parent_task_id")))
  let workflow = text(required(obj, "workflow_id"))
  let digest = text(required(obj, "content_digest"))
  let at_ms = integer(required(obj, "at_ms"))
  let tasks = items(required(obj, "tasks")).map(task)
  let mapping = items(required(obj, "mapping"))
  guard tasks.length() == mapping.length() else {
    raise DecodeFailure("expansion mapping mismatch")
  }
  let candidates : Array[@domain.GraphTask] = []
  for i, entity in tasks {
    let entry = fields(mapping[i])
    guard text(required(entry, "task_id")) == entity.id &&
      entity.stage == Created &&
      entity.created_at_ms == at_ms &&
      entity.updated_at_ms == at_ms &&
      entity.ready_since_ms == None else {
      raise DecodeFailure("expansion task metadata mismatch")
    }
    candidates.push(
      @domain.GraphTask::from_record(
        id=@domain.BoardTaskId(entity.id),
        title=entity.title,
        description=entity.description,
        priority=domain_priority(entity.priority),
        definition_of_done=entity.definition_of_done,
        dependencies=entity.dependencies.map(id => @domain.BoardTaskId(id)),
        local_ref=text(required(entry, "local_ref")),
      ),
    )
  }
  guard @domain.valid_expansion_digest(digest) &&
    @domain.expansion_content_digest(
      expansion~,
      candidates~,
      parent~,
      workflow~,
    ) ==
    digest else {
    raise DecodeFailure("expansion digest mismatch")
  }
  // Reuse the domain's whole-proposal DAG and identity validation on a detached
  // structural baseline. No mutation is exposed to browser command callers.
  let snapshot : @domain.BoardStateSnapshot = {
    revision: 0L,
    attempts: [],
    expansions: [],
    tasks: existing.map(entity => {
      @domain.BoardTask::from_record(
        id=@domain.BoardTaskId(entity.id),
        title=entity.title,
        description=entity.description,
        stage=@domain.Created,
        priority=domain_priority(entity.priority),
        definition_of_done=entity.definition_of_done,
        dependencies=entity.dependencies.map(id => @domain.BoardTaskId(id)),
        created_at_ms=entity.created_at_ms,
        updated_at_ms=entity.updated_at_ms,
        ready_since_ms=entity.ready_since_ms,
      )
    }),
  }
  let state = match @domain.BoardState::from_snapshot(snapshot) {
    Ok(state) => state
    Err(_) => raise DecodeFailure("invalid expansion baseline")
  }
  match
    @domain.BoardDomain::propose(
      state,
      @domain.ExpandGraph(
        expansion~,
        candidates~,
        parent~,
        workflow~,
        at_ms~,
        expected_revision=0L,
      ),
    ) {
    Err(_) => raise DecodeFailure("invalid expansion graph")
    Ok(_) => ()
  }
  existing.map(task => task.copy_detached()) + tasks
}

///|
fn domain_priority(priority : ClientBoardPriority) -> @domain.BoardPriority {
  match priority {
    Low => @domain.Low
    Normal => @domain.Normal
    High => @domain.High
    Critical => @domain.Critical
  }
}
