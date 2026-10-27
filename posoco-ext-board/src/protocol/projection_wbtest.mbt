///|
fn projection_id(value~ : String = "t1") -> @domain.BoardTaskId {
  @domain.BoardTaskId::BoardTaskId(value)
}

///|
fn projection_attempt_id(value~ : String = "a1") -> @domain.AttemptId {
  @domain.AttemptId::AttemptId(value)
}

///|
fn projection_task(
  stage~ : @domain.BoardStage = @domain.Ready,
  ready_since_ms~ : Int64? = Some(15L),
  dependencies~ : Array[@domain.BoardTaskId] = [
    projection_id(value="t2"),
    projection_id(value="t3"),
  ],
  model~ : @domain.ModelSelection? = None,
  review~ : @domain.ReviewReport? = None,
  review_feedback~ : String? = None,
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
    model~,
    review~,
    review_feedback~,
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
  kind~ : @domain.AttemptKind = @domain.Execute,
  status~ : @domain.AttemptStatus = @domain.Queued,
  review~ : @domain.ReviewDecision? = None,
  started_at_ms~ : Int64? = None,
  finished_at_ms~ : Int64? = None,
  updated_at_ms~ : Int64 = 25L,
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
  revision~ : Int64 = 7L,
  tasks~ : Array[@domain.BoardTask] = [],
  attempts~ : Array[@domain.Attempt] = [],
) -> @domain.BoardStateSnapshot {
  { revision, tasks, attempts, expansions: [], }
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
fn expected_task_t1(
  stage~ : String,
  ready_since~ : Json,
  review_feedback~ : Json = Json::null(),
) -> Json {
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
    "user_story": "",
    "implementation_suggestions": "",
    "assignments": [],
    "model": Json::null(),
    "review": Json::null(),
    "review_feedback": review_feedback,
  }
}

///|
fn expected_attempt(
  kind~ : String,
  status~ : String,
  review~ : Json,
  started_at_ms~ : Json,
  finished_at_ms~ : Json,
  updated_at_ms~ : Int32,
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
fn projection_report() -> @domain.ReviewReport {
  @domain.ReviewReport::from_record(
    outcome="Board tickets use a per-ticket model and keep it across work.",
    summary="Adds an optional (slot, effort) selection to the work item.",
    changes=[
      "Work item stores an optional (slot, effort).", "Split children inherit the source selection.",
    ],
    verification=[
      @domain.ReviewEvidence::from_record(
        kind=@domain.ReviewEvidenceKind::Command,
        label="moon test src/domain",
        result=@domain.ReviewEvidenceResult::Passed,
        detail="43 tests",
      ),
      @domain.ReviewEvidence::from_record(
        kind=@domain.ReviewEvidenceKind::Manual,
        label="real-provider mixed-model check",
        result=@domain.ReviewEvidenceResult::NotRun,
        detail="no provider credentials",
      ),
      @domain.ReviewEvidence::from_record(
        kind=@domain.ReviewEvidenceKind::Artifact,
        label="execution log",
        result=@domain.ReviewEvidenceResult::Unknown,
        detail="",
      ),
    ],
    risks=[
      "A removed provider slot fails the run visibly; it never falls back.",
    ],
    notes=["Effort is optional and defaults to the slot default."],
    open_questions=["Should split children inherit effort as well?"],
    artifacts=[
      @domain.ReviewArtifact::from_record(
        kind=@domain.ReviewArtifactKind::File,
        label="records.mbt",
        uri_or_digest="src/domain/records.mbt",
      ),
      @domain.ReviewArtifact::from_record(
        kind=@domain.ReviewArtifactKind::Diff,
        label="patch",
        uri_or_digest="sha256:5f0c9a",
      ),
    ],
  )
}

///|
fn expected_review_json() -> Json {
  {
    "outcome": "Board tickets use a per-ticket model and keep it across work.",
    "summary": "Adds an optional (slot, effort) selection to the work item.",
    "changes": [
      "Work item stores an optional (slot, effort).", "Split children inherit the source selection.",
    ],
    "verification": [
      {
        "kind": "command",
        "label": "moon test src/domain",
        "result": "passed",
        "detail": "43 tests",
      },
      {
        "kind": "manual",
        "label": "real-provider mixed-model check",
        "result": "not_run",
        "detail": "no provider credentials",
      },
      {
        "kind": "artifact",
        "label": "execution log",
        "result": "unknown",
        "detail": "",
      },
    ],
    "risks": [
      "A removed provider slot fails the run visibly; it never falls back.",
    ],
    "notes": ["Effort is optional and defaults to the slot default."],
    "open_questions": ["Should split children inherit effort as well?"],
    "artifacts": [
      {
        "kind": "file",
        "label": "records.mbt",
        "uri_or_digest": "src/domain/records.mbt",
      },
      { "kind": "diff", "label": "patch", "uri_or_digest": "sha256:5f0c9a" },
    ],
  }
}

///|
test "task review projects nested evidence and artifacts, absence is null" {
  assert_eq(
    object_field(task_to_json(projection_task()), "review"),
    Json::null(),
  )
  let reviewed = projection_task(review=Some(projection_report()))
  assert_eq(
    object_field(task_to_json(reviewed), "review"),
    expected_review_json(),
  )
  let event = project_event(
    projection_snapshot(tasks=[reviewed]),
    @domain.TaskUpdated(id=projection_id(), at_ms=20L),
  )
  assert_eq(object_field(object_field(event.payload, "task"), "review"), {
    "outcome": "Board tickets use a per-ticket model and keep it across work.",
    "summary": "Adds an optional (slot, effort) selection to the work item.",
    "changes": [
      "Work item stores an optional (slot, effort).", "Split children inherit the source selection.",
    ],
    "verification": [
      {
        "kind": "command",
        "label": "moon test src/domain",
        "result": "passed",
        "detail": "43 tests",
      },
      {
        "kind": "manual",
        "label": "real-provider mixed-model check",
        "result": "not_run",
        "detail": "no provider credentials",
      },
      {
        "kind": "artifact",
        "label": "execution log",
        "result": "unknown",
        "detail": "",
      },
    ],
    "risks": [
      "A removed provider slot fails the run visibly; it never falls back.",
    ],
    "notes": ["Effort is optional and defaults to the slot default."],
    "open_questions": ["Should split children inherit effort as well?"],
    "artifacts": [
      {
        "kind": "file",
        "label": "records.mbt",
        "uri_or_digest": "src/domain/records.mbt",
      },
      { "kind": "diff", "label": "patch", "uri_or_digest": "sha256:5f0c9a" },
    ],
  })
}

///|
test "projected review arrays are detached from the committed task" {
  let report = projection_report()
  let task = projection_task(review=Some(report))
  let json = task_to_json(task)
  array_field(object_field(json, "review"), "changes").push(
    Json::string("tampered"),
  )
  array_field(object_field(json, "review"), "verification").push(Json::null())
  array_field(object_field(json, "review"), "artifacts").clear()
  assert_eq(task.review.unwrap().changes.length(), 2)
  assert_eq(task.review.unwrap().verification.length(), 3)
  assert_eq(task.review.unwrap().artifacts.length(), 2)
  assert_eq(object_field(task_to_json(task), "review"), expected_review_json())
}

///|
test "every review enum renders one stable wire string" {
  let evidence_kinds : Array[(@domain.ReviewEvidenceKind, String)] = [
    (@domain.ReviewEvidenceKind::Command, "command"),
    (@domain.ReviewEvidenceKind::Test, "test"),
    (@domain.ReviewEvidenceKind::Manual, "manual"),
    (@domain.ReviewEvidenceKind::Artifact, "artifact"),
  ]
  for (kind, name) in evidence_kinds {
    let report = @domain.ReviewReport::from_record(
      outcome="o",
      summary="s",
      changes=[],
      verification=[
        @domain.ReviewEvidence::from_record(
          kind~,
          label="l",
          result=@domain.ReviewEvidenceResult::Passed,
          detail="",
        ),
      ],
      risks=[],
      notes=[],
      open_questions=[],
      artifacts=[],
    )
    let json = object_field(
      task_to_json(projection_task(review=Some(report))),
      "review",
    )
    assert_eq(
      object_field(array_field(json, "verification")[0], "kind"),
      Json::string(name),
    )
  }
  let evidence_results : Array[(@domain.ReviewEvidenceResult, String)] = [
    (@domain.ReviewEvidenceResult::Passed, "passed"),
    (@domain.ReviewEvidenceResult::Failed, "failed"),
    (@domain.ReviewEvidenceResult::NotRun, "not_run"),
    (@domain.ReviewEvidenceResult::Unknown, "unknown"),
  ]
  for (result, name) in evidence_results {
    let report = @domain.ReviewReport::from_record(
      outcome="o",
      summary="s",
      changes=[],
      verification=[
        @domain.ReviewEvidence::from_record(
          kind=@domain.ReviewEvidenceKind::Test,
          label="l",
          result~,
          detail="",
        ),
      ],
      risks=[],
      notes=[],
      open_questions=[],
      artifacts=[],
    )
    let json = object_field(
      task_to_json(projection_task(review=Some(report))),
      "review",
    )
    assert_eq(
      object_field(array_field(json, "verification")[0], "result"),
      Json::string(name),
    )
  }
  let artifact_kinds : Array[(@domain.ReviewArtifactKind, String)] = [
    (@domain.ReviewArtifactKind::File, "file"),
    (@domain.ReviewArtifactKind::Diff, "diff"),
    (@domain.ReviewArtifactKind::Log, "log"),
    (@domain.ReviewArtifactKind::Screenshot, "screenshot"),
    (@domain.ReviewArtifactKind::Url, "url"),
  ]
  for (kind, name) in artifact_kinds {
    let report = @domain.ReviewReport::from_record(
      outcome="o",
      summary="s",
      changes=[],
      verification=[],
      risks=[],
      notes=[],
      open_questions=[],
      artifacts=[
        @domain.ReviewArtifact::from_record(kind~, label="l", uri_or_digest="d"),
      ],
    )
    let json = object_field(
      task_to_json(projection_task(review=Some(report))),
      "review",
    )
    assert_eq(
      object_field(array_field(json, "artifacts")[0], "kind"),
      Json::string(name),
    )
  }
}

///|
test "model changes project the committed task and pinned selection" {
  let pinned = projection_task(
    model=Some(
      @domain.ModelSelection::ModelSelection(
        slot="openai/gpt-5.2",
        effort=Some("high"),
      ),
    ),
  )
  let event = project_event(
    projection_snapshot(tasks=[pinned]),
    @domain.TaskModelChanged(
      id=projection_id(),
      model=Some(
        @domain.ModelSelection::ModelSelection(
          slot="openai/gpt-5.2",
          effort=Some("high"),
        ),
      ),
      at_ms=30L,
    ),
  )
  assert_eq(event.kind, "board.task.model_changed")
  assert_eq(object_field(event.payload, "task"), task_to_json(pinned))
  assert_eq(object_field(event.payload, "model"), {
    "slot": "openai/gpt-5.2",
    "effort": "high",
  })
  assert_eq(object_field(event.payload, "at_ms"), Json::number(30))
}

///|
test "review report set projects the committed task and the report" {
  let report = projection_report()
  let reviewed = projection_task(stage=@domain.Review, review=Some(report))
  let event = project_event(
    projection_snapshot(tasks=[reviewed]),
    @domain.ReviewReportSet(id=projection_id(), review=Some(report), at_ms=40L),
  )
  assert_eq(event.kind, "board.task.review_report_set")
  assert_eq(object_field(event.payload, "task"), task_to_json(reviewed))
  assert_eq(object_field(event.payload, "review"), expected_review_json())
  assert_eq(object_field(event.payload, "at_ms"), Json::number(40))
  // A clear projects the committed task without a report as explicit null.
  let cleared = projection_task(stage=@domain.Running, review=None)
  let clear_event = project_event(
    projection_snapshot(tasks=[cleared]),
    @domain.ReviewReportSet(id=projection_id(), review=None, at_ms=41L),
  )
  assert_eq(clear_event.kind, "board.task.review_report_set")
  assert_eq(object_field(clear_event.payload, "task"), task_to_json(cleared))
  assert_eq(object_field(clear_event.payload, "review"), Json::null())
  assert_eq(object_field(clear_event.payload, "at_ms"), Json::number(41))
}

///|
test "request changes projects the committed ticket and attempt together" {
  let task = projection_task(
    stage=@domain.Ready,
    ready_since_ms=Some(50L),
    review_feedback=Some("add a regression test"),
  )
  let attempt = projection_attempt(
    kind=@domain.Review,
    status=@domain.Running,
    review=Some(@domain.ChangesRequested),
    started_at_ms=Some(30L),
    updated_at_ms=50L,
  )
  let event = project_event(
    projection_snapshot(tasks=[task], attempts=[attempt]),
    @domain.ReviewChangesRequested(
      task_id=projection_id(),
      attempt_id=projection_attempt_id(),
      feedback="add a regression test",
      at_ms=50L,
    ),
  )
  assert_eq(event.kind, "board.task.review_changes_requested")
  assert_eq(event.board_revision, 7L)
  assert_eq(event.payload, {
    "task_id": "t1",
    "task": expected_task_t1(
      stage="ready",
      ready_since=Json::number(50),
      review_feedback=Json::string("add a regression test"),
    ),
    "attempt_id": "a1",
    "attempt": expected_attempt(
      kind="review",
      status="running",
      review="changes_requested",
      started_at_ms=Json::number(30),
      finished_at_ms=Json::null(),
      updated_at_ms=50,
    ),
    "feedback": "add a regression test",
    "at_ms": Json::number(50),
  })
  // A ticket without feedback still renders the field, as explicit null.
  assert_eq(
    object_field(task_to_json(projection_task()), "review_feedback"),
    Json::null(),
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
    (@domain.Cancelled, "cancelled"),
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
    "created_at_ms", "updated_at_ms", "ready_since_ms", "user_story", "implementation_suggestions",
    "assignments", "model", "review", "review_feedback",
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
          "user_story": "",
          "implementation_suggestions": "",
          "assignments": [],
          "model": Json::null(),
          "review": Json::null(),
          "review_feedback": Json::null(),
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
