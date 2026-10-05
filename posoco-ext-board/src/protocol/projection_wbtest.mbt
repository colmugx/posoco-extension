///|
fn projection_id(value? : String = "t1") -> @domain.BoardTaskId {
  @domain.BoardTaskId::BoardTaskId(value)
}

///|
fn projection_attempt_id(value? : String = "a1") -> @domain.AttemptId {
  @domain.AttemptId::AttemptId(value)
}

///|
fn projection_task(
  stage? : @domain.BoardStage = @domain.Ready,
  ready_since_ms? : Int64? = Some(15L),
  dependencies? : Array[@domain.BoardTaskId] = [
    projection_id(value="t2"),
    projection_id(value="t3"),
  ],
) -> @domain.BoardTask {
  @domain.BoardTask::from_record(
    id=projection_id(),
    title="Task t1",
    description="Board task t1",
    stage~,
    priority=@domain.High,
    definition_of_done=["write tests", "review"],
    dependencies~,
    created_at_ms=10L,
    updated_at_ms=20L,
    ready_since_ms~,
  )
}

///|
fn projection_task_t2() -> @domain.BoardTask {
  @domain.BoardTask::from_record(
    id=projection_id(value="t2"),
    title="Task t2",
    description="Board task t2",
    stage=@domain.Created,
    priority=@domain.Normal,
    definition_of_done=[],
    dependencies=[],
    created_at_ms=11L,
    updated_at_ms=11L,
    ready_since_ms=None,
  )
}

///|
fn projection_attempt(
  kind? : @domain.AttemptKind = @domain.Execute,
  status? : @domain.AttemptStatus = @domain.Queued,
  review? : @domain.ReviewDecision? = None,
  started_at_ms? : Int64? = None,
  finished_at_ms? : Int64? = None,
  updated_at_ms? : Int64 = 25L,
) -> @domain.Attempt {
  @domain.Attempt::from_record(
    id=projection_attempt_id(),
    task_id=projection_id(),
    kind~,
    status~,
    review~,
    created_at_ms=25L,
    started_at_ms~,
    finished_at_ms~,
    updated_at_ms~,
  )
}

///|
fn projection_snapshot(
  revision? : Int64 = 7L,
  tasks? : Array[@domain.BoardTask] = [],
  attempts? : Array[@domain.Attempt] = [],
) -> @domain.BoardStateSnapshot {
  { revision, tasks, attempts, }
}

///|
fn text_field(value : Json, key : String) -> String {
  match value {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(Json::String(text)) => text
        _ => abort("missing string field \{key}")
      }
    _ => abort("expected object")
  }
}

///|
fn array_field(value : Json, key : String) -> Array[Json] {
  match value {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(Json::Array(items)) => items
        _ => abort("missing array field \{key}")
      }
    _ => abort("expected object")
  }
}

///|
fn object_field(value : Json, key : String) -> Json {
  match value {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(value) => value
        None => abort("missing field \{key}")
      }
    _ => abort("expected object")
  }
}

///|
fn keys_of(value : Json) -> Array[String] {
  match value {
    Json::Object(fields) => fields.keys().collect()
    _ => abort("expected object")
  }
}

///|
fn expected_task_t1(stage~ : String, ready_since~ : Json) -> Json {
  {
    "id": "t1",
    "title": "Task t1",
    "description": "Board task t1",
    "stage": stage,
    "priority": "high",
    "definition_of_done": ["write tests", "review"],
    "dependencies": ["t2", "t3"],
    "created_at_ms": Json::number(10),
    "updated_at_ms": Json::number(20),
    "ready_since_ms": ready_since,
  }
}

///|
fn expected_attempt(
  kind~ : String,
  status~ : String,
  review~ : Json,
  started_at_ms~ : Json,
  finished_at_ms~ : Json,
  updated_at_ms~ : Int,
) -> Json {
  {
    "id": "a1",
    "task_id": "t1",
    "kind": kind,
    "status": status,
    "review": review,
    "created_at_ms": Json::number(25),
    "started_at_ms": started_at_ms,
    "finished_at_ms": finished_at_ms,
    "updated_at_ms": Json::number(updated_at_ms.to_double()),
  }
}

///|
test "task events project the full committed task under stable kinds" {
  let snapshot = projection_snapshot(
    tasks=[projection_task(), projection_task_t2()],
    attempts=[projection_attempt()],
  )
  let entity = expected_task_t1(stage="ready", ready_since=Json::number(15))
  assert_eq(
    project_event(snapshot, @domain.TaskCreated(id=projection_id(), at_ms=10L)),
    {
      seq: 0L,
      board_revision: 7L,
      kind: "board.task.created",
      scope: None,
      payload: { "task_id": "t1", "task": entity, "at_ms": Json::number(10) },
    },
  )
  assert_eq(
    project_event(snapshot, @domain.TaskUpdated(id=projection_id(), at_ms=20L)),
    {
      seq: 0L,
      board_revision: 7L,
      kind: "board.task.updated",
      scope: None,
      payload: { "task_id": "t1", "task": entity, "at_ms": Json::number(20) },
    },
  )
  assert_eq(
    project_event(
      snapshot,
      @domain.DependenciesSet(
        id=projection_id(),
        dependencies=[projection_id(value="t2"), projection_id(value="t3")],
        at_ms=20L,
      ),
    ),
    {
      seq: 0L,
      board_revision: 7L,
      kind: "board.task.dependencies_changed",
      scope: None,
      payload: {
        "task_id": "t1",
        "task": entity,
        "dependencies": ["t2", "t3"],
        "at_ms": Json::number(20),
      },
    },
  )
  let moved = projection_task(stage=@domain.Running, ready_since_ms=None)
  assert_eq(
    project_event(
      projection_snapshot(tasks=[moved, projection_task_t2()]),
      @domain.TaskStageChanged(
        id=projection_id(),
        from=@domain.Ready,
        to=@domain.Running,
        at_ms=20L,
      ),
    ),
    {
      seq: 0L,
      board_revision: 7L,
      kind: "board.task.stage_changed",
      scope: None,
      payload: {
        "task_id": "t1",
        "task": expected_task_t1(stage="running", ready_since=Json::null()),
        "from": "ready",
        "to": "running",
        "at_ms": Json::number(20),
      },
    },
  )
}

///|
test "attempt and review events project the full committed attempt under stable kinds" {
  let snapshot = projection_snapshot(tasks=[projection_task()], attempts=[
    projection_attempt(),
  ])
  assert_eq(
    project_event(
      snapshot,
      @domain.AttemptQueued(
        id=projection_attempt_id(),
        task_id=projection_id(),
        kind=@domain.Execute,
        at_ms=25L,
      ),
    ),
    {
      seq: 0L,
      board_revision: 7L,
      kind: "board.attempt.queued",
      scope: None,
      payload: {
        "attempt_id": "a1",
        "task_id": "t1",
        "attempt": expected_attempt(
          kind="execute",
          status="queued",
          review=Json::null(),
          started_at_ms=Json::null(),
          finished_at_ms=Json::null(),
          updated_at_ms=25,
        ),
        "kind": "execute",
        "at_ms": Json::number(25),
      },
    },
  )
  let running = projection_attempt(
    kind=@domain.Review,
    status=@domain.Running,
    review=Some(@domain.Pending),
    started_at_ms=Some(30L),
    updated_at_ms=30L,
  )
  assert_eq(
    project_event(
      projection_snapshot(tasks=[projection_task()], attempts=[running]),
      @domain.AttemptStarted(
        id=projection_attempt_id(),
        task_id=projection_id(),
        at_ms=30L,
      ),
    ),
    {
      seq: 0L,
      board_revision: 7L,
      kind: "board.attempt.started",
      scope: None,
      payload: {
        "attempt_id": "a1",
        "task_id": "t1",
        "attempt": expected_attempt(
          kind="review",
          status="running",
          review="pending",
          started_at_ms=Json::number(30),
          finished_at_ms=Json::null(),
          updated_at_ms=30,
        ),
        "at_ms": Json::number(30),
      },
    },
  )
  let finished = projection_attempt(
    status=@domain.Succeeded,
    started_at_ms=Some(30L),
    finished_at_ms=Some(60L),
    updated_at_ms=60L,
  )
  assert_eq(
    project_event(
      projection_snapshot(tasks=[projection_task()], attempts=[finished]),
      @domain.AttemptFinished(
        id=projection_attempt_id(),
        task_id=projection_id(),
        outcome=@domain.Succeeded,
        at_ms=60L,
      ),
    ),
    {
      seq: 0L,
      board_revision: 7L,
      kind: "board.attempt.finished",
      scope: None,
      payload: {
        "attempt_id": "a1",
        "task_id": "t1",
        "attempt": expected_attempt(
          kind="execute",
          status="succeeded",
          review=Json::null(),
          started_at_ms=Json::number(30),
          finished_at_ms=Json::number(60),
          updated_at_ms=60,
        ),
        "outcome": "succeeded",
        "at_ms": Json::number(60),
      },
    },
  )
  let reviewed = projection_attempt(
    kind=@domain.Review,
    status=@domain.Running,
    review=Some(@domain.Approved),
    started_at_ms=Some(30L),
    updated_at_ms=55L,
  )
  assert_eq(
    project_event(
      projection_snapshot(tasks=[projection_task()], attempts=[reviewed]),
      @domain.ReviewRecorded(
        id=projection_attempt_id(),
        task_id=projection_id(),
        decision=@domain.Approved,
        at_ms=55L,
      ),
    ),
    {
      seq: 0L,
      board_revision: 7L,
      kind: "board.review.recorded",
      scope: None,
      payload: {
        "attempt_id": "a1",
        "task_id": "t1",
        "attempt": expected_attempt(
          kind="review",
          status="running",
          review="approved",
          started_at_ms=Json::number(30),
          finished_at_ms=Json::null(),
          updated_at_ms=55,
        ),
        "decision": "approved",
        "at_ms": Json::number(55),
      },
    },
  )
}

///|
test "wire enums render every variant in stable snake case" {
  let stages : Array[(@domain.BoardStage, String)] = [
    (@domain.Created, "created"),
    (@domain.Refining, "refining"),
    (@domain.Ready, "ready"),
    (@domain.Running, "running"),
    (@domain.Review, "review"),
    (@domain.Done, "done"),
    (@domain.Suspended, "suspended"),
  ]
  for (stage, name) in stages {
    let task = projection_task(stage~)
    assert_eq(text_field(task_to_json(task), "stage"), name)
  }
  let priorities : Array[(@domain.BoardPriority, String)] = [
    (@domain.Low, "low"),
    (@domain.Normal, "normal"),
    (@domain.High, "high"),
    (@domain.Critical, "critical"),
  ]
  for (priority, name) in priorities {
    let task = @domain.BoardTask::from_record(
      id=projection_id(),
      title="Task t1",
      description="Board task t1",
      stage=@domain.Created,
      priority~,
      definition_of_done=[],
      dependencies=[],
      created_at_ms=10L,
      updated_at_ms=10L,
      ready_since_ms=None,
    )
    assert_eq(text_field(task_to_json(task), "priority"), name)
  }
  let kinds : Array[(@domain.AttemptKind, String)] = [
    (@domain.Discuss, "discuss"),
    (@domain.Execute, "execute"),
    (@domain.Review, "review"),
  ]
  for (kind, name) in kinds {
    let attempt = projection_attempt(kind~)
    assert_eq(text_field(attempt_to_json(attempt), "kind"), name)
  }
  let statuses : Array[(@domain.AttemptStatus, String)] = [
    (@domain.Queued, "queued"),
    (@domain.Running, "running"),
    (@domain.Succeeded, "succeeded"),
    (@domain.Failed, "failed"),
    (@domain.Cancelled, "cancelled"),
    (@domain.Interrupted, "interrupted"),
  ]
  for (status, name) in statuses {
    let attempt = projection_attempt(status~)
    assert_eq(text_field(attempt_to_json(attempt), "status"), name)
  }
  let reviews : Array[(@domain.ReviewDecision?, Json)] = [
    (None, Json::null()),
    (Some(@domain.Pending), Json::string("pending")),
    (Some(@domain.Approved), Json::string("approved")),
    (Some(@domain.ChangesRequested), Json::string("changes_requested")),
  ]
  for (review, name) in reviews {
    let attempt = projection_attempt(review~)
    assert_eq(object_field(attempt_to_json(attempt), "review"), name)
  }
  let outcomes : Array[(@domain.AttemptOutcome, String)] = [
    (@domain.Succeeded, "succeeded"),
    (@domain.Failed, "failed"),
    (@domain.Cancelled, "cancelled"),
    (@domain.Interrupted, "interrupted"),
  ]
  for (outcome, name) in outcomes {
    let status = match outcome {
      @domain.AttemptOutcome::Succeeded => @domain.AttemptStatus::Succeeded
      @domain.AttemptOutcome::Failed => @domain.AttemptStatus::Failed
      @domain.AttemptOutcome::Cancelled => @domain.AttemptStatus::Cancelled
      @domain.AttemptOutcome::Interrupted => @domain.AttemptStatus::Interrupted
    }
    let attempt = projection_attempt(
      status~,
      started_at_ms=Some(30L),
      finished_at_ms=Some(60L),
      updated_at_ms=60L,
    )
    let wire = project_event(
      projection_snapshot(tasks=[projection_task()], attempts=[attempt]),
      @domain.AttemptFinished(
        id=projection_attempt_id(),
        task_id=projection_id(),
        outcome~,
        at_ms=60L,
      ),
    )
    assert_eq(text_field(wire.payload, "outcome"), name)
  }
}

///|
test "wire payloads carry no schema or store metadata" {
  let snapshot = projection_snapshot(tasks=[projection_task()], attempts=[
    projection_attempt(),
  ])
  assert_eq(keys_of(snapshot_to_json(snapshot)), [
    "revision", "tasks", "attempts",
  ])
  let payload = project_event(
      snapshot,
      @domain.TaskUpdated(id=projection_id(), at_ms=20L),
    ).payload
  assert_eq(keys_of(payload), ["task_id", "task", "at_ms"])
  let schema_keys = keys_of(payload).filter(key => {
    key == "schema_version" || key == "revision" || key == "store"
  })
  assert_eq(schema_keys, [])
  assert_eq(keys_of(task_to_json(projection_task())), [
    "id", "title", "description", "stage", "priority", "definition_of_done", "dependencies",
    "created_at_ms", "updated_at_ms", "ready_since_ms",
  ])
  assert_eq(keys_of(attempt_to_json(projection_attempt())), [
    "id", "task_id", "kind", "status", "review", "created_at_ms", "started_at_ms",
    "finished_at_ms", "updated_at_ms",
  ])
}

///|
test "projected json arrays are detached from the committed snapshot" {
  let snapshot = projection_snapshot(tasks=[projection_task()], attempts=[
    projection_attempt(),
  ])
  let first = snapshot_to_json(snapshot)
  array_field(first, "tasks").push(Json::string("tampered"))
  array_field(array_field(first, "tasks")[0], "definition_of_done").push(
    Json::string("tampered"),
  )
  assert_eq(snapshot.tasks.length(), 1)
  assert_eq(snapshot.tasks[0].definition_of_done, ["write tests", "review"])
  assert_eq(snapshot.attempts.length(), 1)
  assert_eq(snapshot_to_json(snapshot), {
    "revision": Json::number(7),
    "tasks": [expected_task_t1(stage="ready", ready_since=Json::number(15))],
    "attempts": [
      expected_attempt(
        kind="execute",
        status="queued",
        review=Json::null(),
        started_at_ms=Json::null(),
        finished_at_ms=Json::null(),
        updated_at_ms=25,
      ),
    ],
  })
  let event = project_event(
    snapshot,
    @domain.TaskUpdated(id=projection_id(), at_ms=20L),
  )
  array_field(object_field(event.payload, "task"), "definition_of_done").push(
    Json::string("tampered"),
  )
  assert_eq(snapshot.tasks[0].definition_of_done, ["write tests", "review"])
  assert_eq(
    project_event(snapshot, @domain.TaskUpdated(id=projection_id(), at_ms=20L)).payload,
    {
      "task_id": "t1",
      "task": expected_task_t1(stage="ready", ready_since=Json::number(15)),
      "at_ms": Json::number(20),
    },
  )
}

///|
test "projected events are freshly allocated per call" {
  let snapshot = projection_snapshot(revision=1L, tasks=[projection_task()])
  let first = project_event(
    snapshot,
    @domain.TaskCreated(id=projection_id(), at_ms=10L),
  )
  // Same inputs, equal wire content — and the committed revision always
  // comes from the snapshot argument of that very call, never shared state.
  let advanced : @domain.BoardStateSnapshot = { ..snapshot, revision: 2L, }
  let second = project_event(
    advanced,
    @domain.TaskCreated(id=projection_id(), at_ms=10L),
  )
  assert_eq(first.kind, second.kind)
  assert_eq(first.payload, second.payload)
  assert_eq(first.seq, 0L)
  assert_eq(second.seq, 0L)
  assert_eq(first.scope, None)
  assert_eq(second.scope, None)
  assert_eq(first.board_revision, 1L)
  assert_eq(second.board_revision, 2L)
}

///|
test "snapshot payload renders the whole committed board verbatim" {
  let json = snapshot_to_json(projection_snapshot(revision=0L))
  assert_eq(json, { "revision": Json::number(0), "tasks": [], "attempts": [] })
  assert_eq(
    snapshot_to_json(
      projection_snapshot(tasks=[projection_task(), projection_task_t2()], attempts=[
        projection_attempt(
          kind=@domain.Review,
          status=@domain.Running,
          review=Some(@domain.Approved),
          started_at_ms=Some(30L),
          finished_at_ms=Some(60L),
          updated_at_ms=60L,
        ),
      ]),
    ),
    {
      "revision": Json::number(7),
      "tasks": [
        expected_task_t1(stage="ready", ready_since=Json::number(15)),
        {
          "id": "t2",
          "title": "Task t2",
          "description": "Board task t2",
          "stage": "created",
          "priority": "normal",
          "definition_of_done": [],
          "dependencies": [],
          "created_at_ms": Json::number(11),
          "updated_at_ms": Json::number(11),
          "ready_since_ms": Json::null(),
        },
      ],
      "attempts": [
        expected_attempt(
          kind="review",
          status="running",
          review="approved",
          started_at_ms=Json::number(30),
          finished_at_ms=Json::number(60),
          updated_at_ms=60,
        ),
      ],
    },
  )
}
