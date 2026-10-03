///|
fn tid(value : String) -> @domain.BoardTaskId {
  @domain.BoardTaskId::BoardTaskId(value)
}

///|
fn aid(value : String) -> @domain.AttemptId {
  @domain.AttemptId::AttemptId(value)
}

///|
fn fixture() -> @domain.BoardStateSnapshot {
  {
    revision: 17L,
    tasks: [
      @domain.BoardTask::from_record(
        id=tid("a"),
        title="λ task\n\"one\"",
        description="中文",
        stage=@domain.Running,
        priority=@domain.Critical,
        definition_of_done=["tested", "documented"],
        dependencies=[tid("b")],
        created_at_ms=1L,
        updated_at_ms=9007199254740993L,
        ready_since_ms=None,
      ),
      @domain.BoardTask::from_record(
        id=tid("b"),
        title="second",
        description="",
        stage=@domain.Ready,
        priority=@domain.Low,
        definition_of_done=[],
        dependencies=[],
        created_at_ms=0L,
        updated_at_ms=2L,
        ready_since_ms=Some(2L),
      ),
    ],
    attempts: [
      @domain.Attempt::from_record(
        id=aid("x"),
        task_id=tid("a"),
        kind=@domain.Review,
        status=@domain.Running,
        review=Some(@domain.ChangesRequested),
        created_at_ms=3L,
        started_at_ms=Some(4L),
        finished_at_ms=None,
        updated_at_ms=5L,
      ),
      @domain.Attempt::from_record(
        id=aid("y"),
        task_id=tid("b"),
        kind=@domain.Discuss,
        status=@domain.Queued,
        review=None,
        created_at_ms=6L,
        started_at_ms=None,
        finished_at_ms=None,
        updated_at_ms=6L,
      ),
    ],
  }
}

///|
fn all_events() -> Array[@domain.BoardEvent] {
  [
    @domain.TaskCreated(id=tid("a"), at_ms=0L),
    @domain.TaskUpdated(id=tid("a"), at_ms=9223372036854775807L),
    @domain.DependenciesSet(id=tid("a"), dependencies=[tid("b")], at_ms=3L),
    @domain.TaskStageChanged(
      id=tid("a"),
      from=@domain.Running,
      to=@domain.Suspended,
      at_ms=4L,
    ),
    @domain.AttemptQueued(
      id=aid("x"),
      task_id=tid("a"),
      kind=@domain.Execute,
      at_ms=5L,
    ),
    @domain.AttemptStarted(id=aid("x"), task_id=tid("a"), at_ms=6L),
    @domain.AttemptFinished(
      id=aid("x"),
      task_id=tid("a"),
      outcome=@domain.Interrupted,
      at_ms=7L,
    ),
    @domain.ReviewRecorded(
      id=aid("x"),
      task_id=tid("a"),
      decision=@domain.Approved,
      at_ms=8L,
    ),
  ]
}

///|
fn[T] invalid(result : Result[T, BoardStoreError]) -> Unit raise {
  match result {
    Err(InvalidData(_)) => ()
    _ => fail("expected InvalidData")
  }
}

///|
test "schema v1 full snapshot and all fields round trip exactly" {
  let snapshot = { ..fixture(), revision: 9223372036854775807L, }
  let encoded = encode_snapshot(snapshot).unwrap()
  assert_eq(decode_snapshot(encoded), Ok(snapshot))
  assert_eq(
    decode_snapshot(encode_snapshot(empty_snapshot()).unwrap()),
    Ok(empty_snapshot()),
  )
  assert_true(encoded.contains("9007199254740993"))
  assert_true(encoded.contains("schema_version"))
}

///|
test "all task stages priorities attempt kinds statuses and optional reviews" {
  let source = fixture()
  let stages : Array[@domain.BoardStage] = [
    Created,
    Refining,
    Ready,
    Running,
    Review,
    Done,
    Suspended,
  ]
  let priorities : Array[@domain.BoardPriority] = [Low, Normal, High, Critical]
  let kinds : Array[@domain.AttemptKind] = [Discuss, Execute, Review]
  let statuses : Array[@domain.AttemptStatus] = [
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    Interrupted,
  ]
  let reviews : Array[@domain.ReviewDecision?] = [
    None,
    Some(Pending),
    Some(Approved),
    Some(ChangesRequested),
  ]
  for stage in stages {
    for priority in priorities {
      let task = @domain.BoardTask::from_record(
        id=source.tasks[0].id,
        title=source.tasks[0].title,
        description=source.tasks[0].description,
        stage~,
        priority~,
        definition_of_done=source.tasks[0].definition_of_done,
        dependencies=source.tasks[0].dependencies,
        created_at_ms=source.tasks[0].created_at_ms,
        updated_at_ms=source.tasks[0].updated_at_ms,
        ready_since_ms=Some(9223372036854775807L),
      )
      let snapshot = { ..source, tasks: [task, source.tasks[1]], }
      assert_eq(
        decode_snapshot(encode_snapshot(snapshot).unwrap()),
        Ok(snapshot),
      )
    }
  }
  for kind in kinds {
    for status in statuses {
      for review in reviews {
        let attempt = @domain.Attempt::from_record(
          id=source.attempts[0].id,
          task_id=source.attempts[0].task_id,
          kind~,
          status~,
          review~,
          created_at_ms=source.attempts[0].created_at_ms,
          started_at_ms=Some(0L),
          finished_at_ms=Some(9223372036854775807L),
          updated_at_ms=source.attempts[0].updated_at_ms,
        )
        let snapshot = { ..source, attempts: [attempt], }
        assert_eq(
          decode_snapshot(encode_snapshot(snapshot).unwrap()),
          Ok(snapshot),
        )
      }
    }
  }
}

///|
test "every domain event and enum payload round trips without Debug persistence" {
  let events = all_events()
  for event in events {
    assert_eq(decode_event(encode_event(event).unwrap()), Ok(event))
  }
  for
    outcome in [
      @domain.AttemptOutcome::Succeeded,
      Failed,
      Cancelled,
      Interrupted,
    ] {
    let event = @domain.AttemptFinished(
      id=aid("x"),
      task_id=tid("a"),
      outcome~,
      at_ms=0L,
    )
    assert_eq(decode_event(encode_event(event).unwrap()), Ok(event))
  }
  for kind in [@domain.AttemptKind::Discuss, Execute, Review] {
    let event = @domain.AttemptQueued(
      id=aid("x"),
      task_id=tid("a"),
      kind~,
      at_ms=1L,
    )
    assert_eq(decode_event(encode_event(event).unwrap()), Ok(event))
  }
  for decision in [@domain.ReviewDecision::Pending, Approved, ChangesRequested] {
    let event = @domain.ReviewRecorded(
      id=aid("x"),
      task_id=tid("a"),
      decision~,
      at_ms=2L,
    )
    assert_eq(decode_event(encode_event(event).unwrap()), Ok(event))
  }
  for
    from in [
      @domain.BoardStage::Created,
      Refining,
      Ready,
      Running,
      Review,
      Done,
      Suspended,
    ] {
    let event = @domain.TaskStageChanged(id=tid("a"), from~, to=from, at_ms=3L)
    assert_eq(decode_event(encode_event(event).unwrap()), Ok(event))
  }
}

///|
test "snapshot rejects syntax schema incomplete extra and duplicate fields" {
  for
    input in [
      "", "null", "[]", "{}", "{", "{\"schema_version\":2,\"revision\":\"0\",\"tasks\":[],\"attempts\":[]}",
      "{\"schema_version\":1,\"revision\":\"0\",\"tasks\":[]}", "{\"schema_version\":1,\"revision\":\"0\",\"tasks\":[],\"attempts\":[],\"extra\":0}",
      "{\"schema_version\":1,\"schema_version\":1,\"revision\":\"0\",\"tasks\":[],\"attempts\":[]}",
      "{\"schema_version\":1,\"revision\":\"0\",\"revi\\u0073ion\":\"0\",\"tasks\":[],\"attempts\":[]}",
    ] {
    invalid(decode_snapshot(input))
  }
  let base = snapshot_json(fixture())
  for key in ["schema_version", "revision", "tasks", "attempts"] {
    let f = fields(base, ["schema_version", "revision", "tasks", "attempts"])
    let removed = f.copy()
    let _ = removed.remove(key)
    invalid(decode_snapshot(Json::object(removed).stringify()))
  }
}

///|
test "canonical Int64 strict types range and optional timestamp errors" {
  for
    value in [
      Json::number(1),
      Json::number(1.5),
      Json::null(),
      Json::boolean(true),
      Json::string(""),
      Json::string("-1"),
      Json::string("01"),
      Json::string("+1"),
      Json::string("1.0"),
      Json::string("1e3"),
      Json::string(" 1"),
      Json::string("9223372036854775808"),
    ] {
    let snapshot = snapshot_json(fixture())
    let f = match snapshot {
      Json::Object(f) => f
      _ => abort("object")
    }
    f["revision"] = value
    invalid(decode_snapshot(snapshot.stringify()))
    let task = match f["tasks"] {
      Json::Array(tasks) => tasks[0]
      _ => abort("array")
    }
    let task_fields = match task {
      Json::Object(f) => f
      _ => abort("object")
    }
    f["revision"] = number(0L)
    task_fields["ready_since_ms"] = value
    if value != Json::null() {
      invalid(decode_snapshot(snapshot.stringify()))
    }
  }
  invalid(encode_snapshot({ ..fixture(), revision: -1L, }))
}

///|
test "every task and attempt field is required and typed" {
  let source = fixture()
  let task_keys = [
    "id", "title", "description", "stage", "priority", "definition_of_done", "dependencies",
    "created_at_ms", "updated_at_ms", "ready_since_ms",
  ]
  let attempt_keys = [
    "id", "task_id", "kind", "status", "review", "created_at_ms", "started_at_ms",
    "finished_at_ms", "updated_at_ms",
  ]
  for key in task_keys {
    let value = snapshot_json(source)
    let f = match value {
      Json::Object(f) => f
      _ => abort("object")
    }
    let ts = match f["tasks"] {
      Json::Array(a) => a
      _ => abort("array")
    }
    let t = match ts[0] {
      Json::Object(f) => f
      _ => abort("object")
    }
    let _ = t.remove(key)
    invalid(decode_snapshot(value.stringify()))
    t[key] = Json::boolean(false)
    invalid(decode_snapshot(value.stringify()))
  }
  for key in attempt_keys {
    let value = snapshot_json(source)
    let f = match value {
      Json::Object(f) => f
      _ => abort("object")
    }
    let ats = match f["attempts"] {
      Json::Array(a) => a
      _ => abort("array")
    }
    let a = match ats[0] {
      Json::Object(f) => f
      _ => abort("object")
    }
    let _ = a.remove(key)
    invalid(decode_snapshot(value.stringify()))
    a[key] = Json::boolean(false)
    invalid(decode_snapshot(value.stringify()))
  }
  for key in ["stage", "priority"] {
    let value = snapshot_json(source)
    let f = match value {
      Json::Object(f) => f
      _ => abort("object")
    }
    let ts = match f["tasks"] {
      Json::Array(a) => a
      _ => abort("array")
    }
    let t = match ts[0] {
      Json::Object(f) => f
      _ => abort("object")
    }
    t[key] = "unknown"
    invalid(decode_snapshot(value.stringify()))
  }
  for key in ["kind", "status", "review"] {
    let value = snapshot_json(source)
    let f = match value {
      Json::Object(f) => f
      _ => abort("object")
    }
    let ats = match f["attempts"] {
      Json::Array(a) => a
      _ => abort("array")
    }
    let a = match ats[0] {
      Json::Object(f) => f
      _ => abort("object")
    }
    a[key] = "unknown"
    invalid(decode_snapshot(value.stringify()))
  }
}

///|
test "snapshot identity dependency graph and input validation errors" {
  let s = fixture()
  invalid(encode_snapshot({ ..s, tasks: [s.tasks[0], s.tasks[0]], }))
  invalid(encode_snapshot({ ..s, attempts: [s.attempts[0], s.attempts[0]], }))
  invalid(
    encode_snapshot({
      ..s,
      attempts: [
        @domain.Attempt::from_record(
          id=s.attempts[0].id,
          task_id=tid("missing"),
          kind=s.attempts[0].kind,
          status=s.attempts[0].status,
          review=s.attempts[0].review,
          created_at_ms=s.attempts[0].created_at_ms,
          started_at_ms=s.attempts[0].started_at_ms,
          finished_at_ms=s.attempts[0].finished_at_ms,
          updated_at_ms=s.attempts[0].updated_at_ms,
        ),
      ],
    }),
  )
  for dependencies in [[tid("missing")], [tid("a")], [tid("b"), tid("b")]] {
    invalid(
      encode_snapshot({
        ..s,
        tasks: [
          @domain.BoardTask::from_record(
            id=s.tasks[0].id,
            title=s.tasks[0].title,
            description=s.tasks[0].description,
            stage=s.tasks[0].stage,
            priority=s.tasks[0].priority,
            definition_of_done=s.tasks[0].definition_of_done,
            dependencies~,
            created_at_ms=s.tasks[0].created_at_ms,
            updated_at_ms=s.tasks[0].updated_at_ms,
            ready_since_ms=s.tasks[0].ready_since_ms,
          ),
          s.tasks[1],
        ],
      }),
    )
  }
  invalid(
    encode_snapshot({
      ..s,
      tasks: [
        s.tasks[0],
        @domain.BoardTask::from_record(
          id=s.tasks[1].id,
          title=s.tasks[1].title,
          description=s.tasks[1].description,
          stage=s.tasks[1].stage,
          priority=s.tasks[1].priority,
          definition_of_done=s.tasks[1].definition_of_done,
          dependencies=[tid("a")],
          created_at_ms=s.tasks[1].created_at_ms,
          updated_at_ms=s.tasks[1].updated_at_ms,
          ready_since_ms=s.tasks[1].ready_since_ms,
        ),
      ],
    }),
  )
  for
    task in [
      @domain.BoardTask::from_record(
        id=tid(""),
        title=s.tasks[0].title,
        description=s.tasks[0].description,
        stage=s.tasks[0].stage,
        priority=s.tasks[0].priority,
        definition_of_done=s.tasks[0].definition_of_done,
        dependencies=s.tasks[0].dependencies,
        created_at_ms=s.tasks[0].created_at_ms,
        updated_at_ms=s.tasks[0].updated_at_ms,
        ready_since_ms=s.tasks[0].ready_since_ms,
      ),
      @domain.BoardTask::from_record(
        id=s.tasks[0].id,
        title="",
        description=s.tasks[0].description,
        stage=s.tasks[0].stage,
        priority=s.tasks[0].priority,
        definition_of_done=s.tasks[0].definition_of_done,
        dependencies=s.tasks[0].dependencies,
        created_at_ms=s.tasks[0].created_at_ms,
        updated_at_ms=s.tasks[0].updated_at_ms,
        ready_since_ms=s.tasks[0].ready_since_ms,
      ),
      @domain.BoardTask::from_record(
        id=s.tasks[0].id,
        title=s.tasks[0].title,
        description=s.tasks[0].description,
        stage=s.tasks[0].stage,
        priority=s.tasks[0].priority,
        definition_of_done=[""],
        dependencies=s.tasks[0].dependencies,
        created_at_ms=s.tasks[0].created_at_ms,
        updated_at_ms=s.tasks[0].updated_at_ms,
        ready_since_ms=s.tasks[0].ready_since_ms,
      ),
      @domain.BoardTask::from_record(
        id=s.tasks[0].id,
        title=s.tasks[0].title,
        description=s.tasks[0].description,
        stage=s.tasks[0].stage,
        priority=s.tasks[0].priority,
        definition_of_done=s.tasks[0].definition_of_done,
        dependencies=s.tasks[0].dependencies,
        created_at_ms=-1L,
        updated_at_ms=s.tasks[0].updated_at_ms,
        ready_since_ms=s.tasks[0].ready_since_ms,
      ),
      @domain.BoardTask::from_record(
        id=s.tasks[0].id,
        title=s.tasks[0].title,
        description=s.tasks[0].description,
        stage=s.tasks[0].stage,
        priority=s.tasks[0].priority,
        definition_of_done=s.tasks[0].definition_of_done,
        dependencies=s.tasks[0].dependencies,
        created_at_ms=s.tasks[0].created_at_ms,
        updated_at_ms=-1L,
        ready_since_ms=s.tasks[0].ready_since_ms,
      ),
      @domain.BoardTask::from_record(
        id=s.tasks[0].id,
        title=s.tasks[0].title,
        description=s.tasks[0].description,
        stage=s.tasks[0].stage,
        priority=s.tasks[0].priority,
        definition_of_done=s.tasks[0].definition_of_done,
        dependencies=s.tasks[0].dependencies,
        created_at_ms=s.tasks[0].created_at_ms,
        updated_at_ms=s.tasks[0].updated_at_ms,
        ready_since_ms=Some(-1L),
      ),
    ] {
    invalid(encode_snapshot({ ..s, tasks: [task, s.tasks[1]], }))
  }
  for
    attempt in [
      @domain.Attempt::from_record(
        id=aid(""),
        task_id=s.attempts[0].task_id,
        kind=s.attempts[0].kind,
        status=s.attempts[0].status,
        review=s.attempts[0].review,
        created_at_ms=s.attempts[0].created_at_ms,
        started_at_ms=s.attempts[0].started_at_ms,
        finished_at_ms=s.attempts[0].finished_at_ms,
        updated_at_ms=s.attempts[0].updated_at_ms,
      ),
      @domain.Attempt::from_record(
        id=s.attempts[0].id,
        task_id=s.attempts[0].task_id,
        kind=s.attempts[0].kind,
        status=s.attempts[0].status,
        review=s.attempts[0].review,
        created_at_ms=-1L,
        started_at_ms=s.attempts[0].started_at_ms,
        finished_at_ms=s.attempts[0].finished_at_ms,
        updated_at_ms=s.attempts[0].updated_at_ms,
      ),
      @domain.Attempt::from_record(
        id=s.attempts[0].id,
        task_id=s.attempts[0].task_id,
        kind=s.attempts[0].kind,
        status=s.attempts[0].status,
        review=s.attempts[0].review,
        created_at_ms=s.attempts[0].created_at_ms,
        started_at_ms=s.attempts[0].started_at_ms,
        finished_at_ms=s.attempts[0].finished_at_ms,
        updated_at_ms=-1L,
      ),
      @domain.Attempt::from_record(
        id=s.attempts[0].id,
        task_id=s.attempts[0].task_id,
        kind=s.attempts[0].kind,
        status=s.attempts[0].status,
        review=s.attempts[0].review,
        created_at_ms=s.attempts[0].created_at_ms,
        started_at_ms=Some(-1L),
        finished_at_ms=s.attempts[0].finished_at_ms,
        updated_at_ms=s.attempts[0].updated_at_ms,
      ),
      @domain.Attempt::from_record(
        id=s.attempts[0].id,
        task_id=s.attempts[0].task_id,
        kind=s.attempts[0].kind,
        status=s.attempts[0].status,
        review=s.attempts[0].review,
        created_at_ms=s.attempts[0].created_at_ms,
        started_at_ms=s.attempts[0].started_at_ms,
        finished_at_ms=Some(-1L),
        updated_at_ms=s.attempts[0].updated_at_ms,
      ),
    ] {
    invalid(encode_snapshot({ ..s, attempts: [attempt], }))
  }
}

///|
test "each event rejects missing extra mistyped fields unknown enums versions and ids" {
  for event in all_events() {
    let value = event_json(event)
    let f = match value {
      Json::Object(f) => f
      _ => abort("object")
    }
    for key in f.keys().collect() {
      let changed = f.copy()
      let _ = changed.remove(key)
      invalid(decode_event(Json::object(changed).stringify()))
      changed[key] = Json::boolean(false)
      invalid(decode_event(Json::object(changed).stringify()))
    }
    for
      (key, value) in [
        ("schema_version", Json::number(2)),
        ("type", Json::string("unknown")),
        ("id", Json::string("")),
        ("at_ms", Json::string("-1")),
        ("extra", Json::null()),
      ] {
      let changed = f.copy()
      changed[key] = value
      invalid(decode_event(Json::object(changed).stringify()))
    }
    for key in ["from", "to", "kind", "outcome", "decision"] {
      if f.contains(key) {
        let changed = f.copy()
        changed[key] = "unknown"
        invalid(decode_event(Json::object(changed).stringify()))
      }
    }
  }
  invalid(encode_event(@domain.TaskCreated(id=tid("a"), at_ms=-1L)))
  invalid(decode_event("null"))
  invalid(decode_event("{"))
}

///|
test "strict JSONL ignores only malformed last physical unterminated line" {
  let events = all_events()
  let lines = events.map(event => journal_line(event).unwrap())
  let complete = lines.join("\n") + "\n"
  assert_eq(decode_journal_events(complete), Ok(events))
  assert_eq(decode_journal_events(lines.join("\n")), Ok(events))
  assert_eq(decode_journal_events(complete + "{\"partial\":"), Ok(events))
  invalid(decode_journal_events(complete + "{}"))
  assert_eq(decode_journal_events(""), Ok([]))
  assert_eq(decode_journal_events("{"), Ok([]))
  invalid(decode_journal_events(complete + "{\n"))
  invalid(decode_journal_events(complete + "{}\n"))
  invalid(decode_journal_events("{\n" + complete))
  invalid(decode_journal_events("\n"))
  invalid(decode_journal_events(complete + "\n"))
  assert_eq(decode_journal_events(lines.join("\r\n") + "\r\n"), Ok(events))
  let retained = scan_journal(complete + "partial").unwrap()
  assert_eq(retained.retained, complete)
  assert_false(retained.add_newline)
  assert_true(scan_journal(lines.join("\n")).unwrap().add_newline)
}

///|
test "pure recovery normalizes all running records once with explicit time" {
  let source = fixture()
  let recovered = recover_snapshot(source, at_ms=123L).unwrap()
  assert_eq(source, fixture())
  assert_eq(recovered.snapshot.revision, source.revision + 1L)
  assert_eq(recovered.snapshot.tasks[0].stage, @domain.Suspended)
  assert_eq(recovered.snapshot.tasks[0].updated_at_ms, 123L)
  assert_eq(recovered.snapshot.tasks[0].ready_since_ms, None)
  assert_eq(recovered.snapshot.attempts[0].status, @domain.Interrupted)
  assert_eq(recovered.snapshot.attempts[0].finished_at_ms, Some(123L))
  assert_eq(
    recovered.snapshot.attempts[0].started_at_ms,
    source.attempts[0].started_at_ms,
  )
  assert_eq(recovered.snapshot.attempts[0].review, source.attempts[0].review)
  assert_eq(recovered.snapshot.tasks[1], source.tasks[1])
  assert_eq(recovered.snapshot.attempts[1], source.attempts[1])
  assert_eq(recovered.events, [
    @domain.TaskStageChanged(
      id=tid("a"),
      from=@domain.Running,
      to=@domain.Suspended,
      at_ms=123L,
    ),
    @domain.AttemptFinished(
      id=aid("x"),
      task_id=tid("a"),
      outcome=@domain.Interrupted,
      at_ms=123L,
    ),
  ])
  let second = recover_snapshot(recovered.snapshot, at_ms=999L).unwrap()
  assert_eq(second.snapshot, recovered.snapshot)
  assert_eq(second.events, [])
  source.tasks[0].definition_of_done.push("late")
  assert_eq(recovered.snapshot.tasks[0].definition_of_done, [
    "tested", "documented",
  ])
  invalid(recover_snapshot(fixture(), at_ms=-1L))
  invalid(
    recover_snapshot({ ..fixture(), revision: 9223372036854775807L, }, at_ms=0L),
  )
  assert_eq(
    recover_snapshot(empty_snapshot(), at_ms=0L).unwrap().snapshot.revision,
    0L,
  )
}

///|
test "recovery task and attempt running states are independent" {
  let s = fixture()
  let only_tasks = { ..s, attempts: [], }
  assert_eq(recover_snapshot(only_tasks, at_ms=1L).unwrap().events.length(), 1)
  let only_attempts = {
    ..s,
    tasks: [
      @domain.BoardTask::from_record(
        id=s.tasks[0].id,
        title=s.tasks[0].title,
        description=s.tasks[0].description,
        stage=@domain.Done,
        priority=s.tasks[0].priority,
        definition_of_done=s.tasks[0].definition_of_done,
        dependencies=s.tasks[0].dependencies,
        created_at_ms=s.tasks[0].created_at_ms,
        updated_at_ms=s.tasks[0].updated_at_ms,
        ready_since_ms=s.tasks[0].ready_since_ms,
      ),
      s.tasks[1],
    ],
  }
  let r = recover_snapshot(only_attempts, at_ms=1L).unwrap()
  assert_eq(r.events.length(), 1)
  assert_eq(r.snapshot.tasks, only_attempts.tasks)
}

///|
async test "memory store detaches requests results nested arrays and events" {
  let store = MemoryBoardStore::MemoryBoardStore()
  assert_eq(store.load().map(loaded => loaded.snapshot), Ok(empty_snapshot()))
  let snapshot = fixture()
  let events = all_events()
  assert_eq(store.persist(snapshot, events), Ok(()))
  snapshot.tasks[0].definition_of_done.push("caller")
  snapshot.tasks[0].dependencies.clear()
  snapshot.tasks.clear()
  snapshot.attempts.clear()
  match events[2] {
    @domain.DependenciesSet(dependencies~, ..) => dependencies.clear()
    _ => abort("event")
  }
  events.clear()
  assert_eq(store.load().map(loaded => loaded.snapshot), Ok(fixture()))
  assert_eq(
    store.load().unwrap().journal.map(record => record.event),
    all_events(),
  )
  let result = store.load().map(loaded => loaded.snapshot).unwrap()
  result.tasks[0].dependencies.clear()
  result.tasks[0].definition_of_done.clear()
  result.tasks.clear()
  result.attempts.clear()
  let audit = store.load().unwrap().journal.map(record => record.event)
  match audit[2] {
    @domain.DependenciesSet(dependencies~, ..) => dependencies.clear()
    _ => abort("event")
  }
  audit.clear()
  assert_eq(store.load().map(loaded => loaded.snapshot), Ok(fixture()))
  assert_eq(
    store.load().unwrap().journal.map(record => record.event),
    all_events(),
  )
  invalid(store.persist({ ..fixture(), revision: -1L, }, []))
  invalid(store.persist(fixture(), [@domain.TaskCreated(id=tid(""), at_ms=1L)]))
  assert_eq(store.load().map(loaded => loaded.snapshot), Ok(fixture()))
  assert_eq(
    store.load().unwrap().journal.map(record => record.event),
    all_events(),
  )
}

///|
async test "load recover persist helper second memory restart is a no-op" {
  let store = MemoryBoardStore::MemoryBoardStore()
  assert_eq(store.persist(fixture(), []), Ok(()))
  let first = load_recover_persist(store, at_ms=123L).unwrap()
  let second = load_recover_persist(store, at_ms=999L).unwrap()
  assert_eq(first.snapshot.revision, 18L)
  assert_eq(second.snapshot, first.snapshot)
  assert_eq(second.events, [])
  assert_eq(
    store.load().unwrap().journal.map(record => record.event),
    first.events,
  )
}

///|
test "from domain snapshot converts every field and detaches arrays" {
  let proposal = @domain.BoardDomain::propose(
    @domain.BoardState::BoardState(),
    @domain.CreateTask(
      id=tid("a"),
      title="a",
      description="description",
      priority=@domain.High,
      definition_of_done=["done"],
      dependencies=[],
      at_ms=123L,
      expected_revision=0L,
    ),
  ).unwrap()
  let source = proposal.next_state.snapshot()
  let converted = source.copy_detached()
  let task = source.tasks[0]
  assert_eq(
    task_json(converted.tasks[0]),
    Json::object({
      "id": "a",
      "title": "a",
      "description": "description",
      "stage": "Created",
      "priority": "High",
      "definition_of_done": ["done"],
      "dependencies": [],
      "created_at_ms": "123",
      "updated_at_ms": "123",
      "ready_since_ms": Json::null(),
    }),
  )
  task.definition_of_done.push("late")
  source.tasks.clear()
  assert_eq(converted.tasks[0].definition_of_done, ["done"])
  assert_eq(converted.revision, 1L)
}

///|
fn journal_line(
  event : @domain.BoardEvent,
  revision? : Int64 = 17L,
) -> Result[String, BoardStoreError] {
  encode_journal_record({ schema_version: 1, revision, event, })
}

///|
fn decode_journal_events(
  input : String,
) -> Result[Array[@domain.BoardEvent], BoardStoreError] {
  decode_journal(input).map(journal => journal.map(record => record.event))
}

///|
test "journal record schema revision and every typed event round trip exactly" {
  for event in all_events() {
    let record : JournalRecord = {
      schema_version: 1,
      revision: 9223372036854775807L,
      event,
    }
    let wire = encode_journal_record(record).unwrap()
    assert_eq(decode_journal_record(wire), Ok(record))
    assert_eq(decode_journal(wire + "\n"), Ok([record]))
    assert_true(wire.contains("9223372036854775807"))
  }
  let record = records(9007199254740993L, [all_events()[0]])[0]
  for field in ["schema_version", "revision", "type", "id", "at_ms"] {
    let f = match journal_record_json(record) {
      Json::Object(f) => f
      _ => abort("object")
    }
    let _ = f.remove(field)
    invalid(decode_journal_record(Json::object(f).stringify()))
  }
  for revision in ["-1", "01", "9223372036854775808", "+1", "1.0"] {
    let wire = encode_journal_record(record)
      .unwrap()
      .replace(old="9007199254740993", new=revision)
    invalid(decode_journal_record(wire))
  }
  for schema_version in [-1, 0, 2] {
    invalid(encode_journal_record({ ..record, schema_version, }))
  }
  invalid(encode_journal_record({ ..record, revision: -1L, }))
  for wire in ["{}", "null", "[]", "{\"revision\":\"0\"}"] {
    invalid(decode_journal_record(wire))
  }
}

///|
test "unterminated valid JSON never bypasses strict journal schema validation" {
  let prefix = journal_line(all_events()[0]).unwrap() + "\n"
  let valid = journal_line(all_events()[1]).unwrap()
  let invalid_lines = [
    "{}",
    "null",
    "[]",
    "true",
    "0",
    encode_event(all_events()[1]).unwrap(),
    valid.replace(old="TaskUpdated", new="Unknown"),
    valid.replace(old="\"schema_version\":1", new="\"schema_version\":2"),
    valid.replace(old="\"revision\":\"17\"", new="\"revision\":17"),
    valid.replace(old="\"revision\":", new="\"revision\":\"1\",\"revision\":"),
  ]
  for tail in invalid_lines {
    invalid(decode_journal(prefix + tail))
    invalid(decode_journal(prefix + tail + "\n"))
  }
  assert_eq(
    decode_journal(prefix + "{\"revision\":"),
    Ok(records(17L, [all_events()[0]])),
  )
  assert_eq(
    decode_journal(prefix + valid),
    Ok(records(17L, [all_events()[0], all_events()[1]])),
  )
}

///|
async test "memory load shares revision-tagged journal semantics and detaches records" {
  let memory = MemoryBoardStore::MemoryBoardStore()
  assert_eq(memory.load(), Ok({ snapshot: empty_snapshot(), journal: [], }))
  let events = all_events()
  assert_eq(memory.persist(fixture(), events), Ok(()))
  let next = { ..fixture(), revision: 18L, }
  assert_eq(memory.persist(next, [events[0]]), Ok(()))
  let expected = records(17L, all_events())
  expected.append(records(18L, [all_events()[0]]))
  assert_eq(memory.load(), Ok({ snapshot: next, journal: expected, }))
  let loaded = memory.load().unwrap()
  match loaded.journal[2].event {
    @domain.DependenciesSet(dependencies~, ..) => dependencies.clear()
    _ => abort("event")
  }
  loaded.journal.clear()
  loaded.snapshot.tasks[0].definition_of_done.clear()
  assert_eq(memory.load(), Ok({ snapshot: next, journal: expected, }))
}

///|
test "recovery changed is explicit with exactly one revision and supplied time" {
  let first = recover_snapshot(fixture(), at_ms=321L).unwrap()
  assert_true(first.changed)
  assert_eq(first.snapshot.revision, 18L)
  assert_eq(first.snapshot.tasks[0].updated_at_ms, 321L)
  assert_eq(first.snapshot.attempts[0].finished_at_ms, Some(321L))
  let second = recover_snapshot(first.snapshot, at_ms=654L).unwrap()
  assert_false(second.changed)
  assert_eq(second.snapshot, first.snapshot)
  assert_eq(second.events, [])
}
