///|
/// S3B2B1 wire projection: the committed Board domain becomes the
/// authoritative snapshot payload and ordered wire events. These functions
/// are pure and synchronous — they allocate fresh JSON and wire values and
/// never touch transport sequencing or the persistence codecs. Enum values
/// render as stable lowercase snake_case strings; every task/attempt record
/// field is present, with JSON null for absent optional fields.
///
/// `project_event` renders the full committed entity the event affected
/// under `task`/`attempt` — a valid commit always leaves that entity in its
/// snapshot. It deliberately emits `seq=0` (the hub owns the transport
/// sequence) and `scope=None` (domain commits carry no Posoco run
/// attribution); `board_revision` is the committed revision of the snapshot
/// the event belongs to.

///|
fn wire_number(value : Int64) -> Json {
  Json::number(value.to_double())
}

///|
fn wire_optional_number(value : Int64?) -> Json {
  match value {
    Some(value) => wire_number(value)
    None => Json::null()
  }
}

///|
fn wire_ids(ids : Array[@domain.BoardTaskId]) -> Json {
  Json::array(ids.map(id => Json::string(id.value)))
}

///|
fn wire_stage(value : @domain.BoardStage) -> Json {
  Json::string(
    match value {
      Created => "created"
      Refining => "refining"
      Ready => "ready"
      Running => "running"
      Review => "review"
      Done => "done"
      Suspended => "suspended"
    },
  )
}

///|
fn wire_priority(value : @domain.BoardPriority) -> Json {
  Json::string(
    match value {
      Low => "low"
      Normal => "normal"
      High => "high"
      Critical => "critical"
    },
  )
}

///|
fn wire_kind(value : @domain.AttemptKind) -> Json {
  Json::string(
    match value {
      Discuss => "discuss"
      Execute => "execute"
      Review => "review"
    },
  )
}

///|
fn wire_status(value : @domain.AttemptStatus) -> Json {
  Json::string(
    match value {
      Queued => "queued"
      Running => "running"
      Succeeded => "succeeded"
      Failed => "failed"
      Cancelled => "cancelled"
      Interrupted => "interrupted"
    },
  )
}

///|
fn wire_outcome(value : @domain.AttemptOutcome) -> Json {
  Json::string(
    match value {
      Succeeded => "succeeded"
      Failed => "failed"
      Cancelled => "cancelled"
      Interrupted => "interrupted"
    },
  )
}

///|
fn wire_decision(value : @domain.ReviewDecision) -> Json {
  Json::string(
    match value {
      Pending => "pending"
      Approved => "approved"
      ChangesRequested => "changes_requested"
    },
  )
}

///|
fn wire_optional_decision(value : @domain.ReviewDecision?) -> Json {
  match value {
    Some(value) => wire_decision(value)
    None => Json::null()
  }
}

///|
/// Full committed task on the wire: all ten record fields, snake_case enum
/// strings and JSON null for the absent `ready_since_ms`. The nested arrays
/// are re-allocated, never aliased from the domain record.
pub fn task_to_json(task : @domain.BoardTask) -> Json {
  Json::object({
    "id": Json::string(task.id.value),
    "title": Json::string(task.title),
    "description": Json::string(task.description),
    "stage": wire_stage(task.stage),
    "priority": wire_priority(task.priority),
    "definition_of_done": Json::array(
      task.definition_of_done.map(item => Json::string(item)),
    ),
    "dependencies": wire_ids(task.dependencies),
    "created_at_ms": wire_number(task.created_at_ms),
    "updated_at_ms": wire_number(task.updated_at_ms),
    "ready_since_ms": wire_optional_number(task.ready_since_ms),
  })
}

///|
/// Full committed attempt on the wire: all nine record fields, snake_case
/// enum strings and JSON null for the absent `review`, `started_at_ms` and
/// `finished_at_ms`.
pub fn attempt_to_json(attempt : @domain.Attempt) -> Json {
  Json::object({
    "id": Json::string(attempt.id.value),
    "task_id": Json::string(attempt.task_id.value),
    "kind": wire_kind(attempt.kind),
    "status": wire_status(attempt.status),
    "review": wire_optional_decision(attempt.review),
    "created_at_ms": wire_number(attempt.created_at_ms),
    "started_at_ms": wire_optional_number(attempt.started_at_ms),
    "finished_at_ms": wire_optional_number(attempt.finished_at_ms),
    "updated_at_ms": wire_number(attempt.updated_at_ms),
  })
}

///|
/// Whole committed board as the authoritative snapshot payload. Records are
/// rendered in their detached listing order; nothing on the wire identifies
/// the host, the store or the instance token.
pub fn snapshot_to_json(snapshot : @domain.BoardStateSnapshot) -> Json {
  Json::object({
    "revision": wire_number(snapshot.revision),
    "tasks": Json::array(snapshot.tasks.map(task => task_to_json(task))),
    "attempts": Json::array(
      snapshot.attempts.map(attempt => attempt_to_json(attempt)),
    ),
  })
}

///|
/// The committed task a projected event affected. A valid commit always
/// leaves the affected entity in its snapshot, so a miss is a caller
/// contract violation and aborts instead of projecting bare ids.
fn committed_task(
  snapshot : @domain.BoardStateSnapshot,
  id : @domain.BoardTaskId,
) -> @domain.BoardTask {
  for task in snapshot.tasks {
    if task.id == id {
      return task
    }
  }
  abort("project_event: task \{id.value} missing from the committed snapshot")
}

///|
/// The committed attempt a projected event affected; see `committed_task`.
fn committed_attempt(
  snapshot : @domain.BoardStateSnapshot,
  id : @domain.AttemptId,
) -> @domain.Attempt {
  for attempt in snapshot.attempts {
    if attempt.id == id {
      return attempt
    }
  }
  abort(
    "project_event: attempt \{id.value} missing from the committed snapshot",
  )
}

///|
fn wire_event(
  kind~ : String,
  payload~ : Array[(String, Json)],
) -> BoardWireEvent {
  let fields : Map[String, Json] = Map::from_array([])
  for (key, value) in payload {
    fields[key] = value
  }
  {
    seq: 0L,
    board_revision: 0L,
    kind,
    scope: None,
    payload: Json::object(fields),
  }
}

///|
/// Project one committed domain event against the snapshot of the
/// transaction that produced it. The payload carries the stable event kind
/// metadata plus the full committed task/attempt entity. Transport `seq`
/// stays zero until the runtime's commit hook publishes the event into the
/// telemetry hub, which mints the sequence; scope stays absent because a
/// domain commit carries no Posoco attribution.
pub fn project_event(
  snapshot : @domain.BoardStateSnapshot,
  event : @domain.BoardEvent,
) -> BoardWireEvent {
  let wire = match event {
    TaskCreated(id~, at_ms~) =>
      wire_event(kind="board.task.created", payload=[
        ("task_id", Json::string(id.value)),
        ("task", task_to_json(committed_task(snapshot, id))),
        ("at_ms", wire_number(at_ms)),
      ])
    TaskUpdated(id~, at_ms~) =>
      wire_event(kind="board.task.updated", payload=[
        ("task_id", Json::string(id.value)),
        ("task", task_to_json(committed_task(snapshot, id))),
        ("at_ms", wire_number(at_ms)),
      ])
    DependenciesSet(id~, dependencies~, at_ms~) =>
      wire_event(kind="board.task.dependencies_changed", payload=[
        ("task_id", Json::string(id.value)),
        ("task", task_to_json(committed_task(snapshot, id))),
        ("dependencies", wire_ids(dependencies)),
        ("at_ms", wire_number(at_ms)),
      ])
    TaskStageChanged(id~, from~, to~, at_ms~) =>
      wire_event(kind="board.task.stage_changed", payload=[
        ("task_id", Json::string(id.value)),
        ("task", task_to_json(committed_task(snapshot, id))),
        ("from", wire_stage(from)),
        ("to", wire_stage(to)),
        ("at_ms", wire_number(at_ms)),
      ])
    AttemptQueued(id~, task_id~, kind~, at_ms~) =>
      wire_event(kind="board.attempt.queued", payload=[
        ("attempt_id", Json::string(id.value)),
        ("task_id", Json::string(task_id.value)),
        ("attempt", attempt_to_json(committed_attempt(snapshot, id))),
        ("kind", wire_kind(kind)),
        ("at_ms", wire_number(at_ms)),
      ])
    AttemptStarted(id~, task_id~, at_ms~) =>
      wire_event(kind="board.attempt.started", payload=[
        ("attempt_id", Json::string(id.value)),
        ("task_id", Json::string(task_id.value)),
        ("attempt", attempt_to_json(committed_attempt(snapshot, id))),
        ("at_ms", wire_number(at_ms)),
      ])
    AttemptFinished(id~, task_id~, outcome~, at_ms~) =>
      wire_event(kind="board.attempt.finished", payload=[
        ("attempt_id", Json::string(id.value)),
        ("task_id", Json::string(task_id.value)),
        ("attempt", attempt_to_json(committed_attempt(snapshot, id))),
        ("outcome", wire_outcome(outcome)),
        ("at_ms", wire_number(at_ms)),
      ])
    ReviewRecorded(id~, task_id~, decision~, at_ms~) =>
      wire_event(kind="board.review.recorded", payload=[
        ("attempt_id", Json::string(id.value)),
        ("task_id", Json::string(task_id.value)),
        ("attempt", attempt_to_json(committed_attempt(snapshot, id))),
        ("decision", wire_decision(decision)),
        ("at_ms", wire_number(at_ms)),
      ])
  }
  { ..wire, board_revision: snapshot.revision, }
}
