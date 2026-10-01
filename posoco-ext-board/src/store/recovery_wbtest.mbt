///|
test "recovery changes several running tasks and attempts with one revision" {
  let s = fixture()
  let tasks = [
    s.tasks[0],
    @domain.BoardTask::from_record(
      id=s.tasks[1].id,
      title=s.tasks[1].title,
      description=s.tasks[1].description,
      stage=@domain.Running,
      priority=s.tasks[1].priority,
      definition_of_done=s.tasks[1].definition_of_done,
      dependencies=s.tasks[1].dependencies,
      created_at_ms=s.tasks[1].created_at_ms,
      updated_at_ms=s.tasks[1].updated_at_ms,
      ready_since_ms=None,
    ),
  ]
  let attempts = [
    s.attempts[0],
    @domain.Attempt::from_record(
      id=s.attempts[1].id,
      task_id=s.attempts[1].task_id,
      kind=s.attempts[1].kind,
      status=@domain.Running,
      review=s.attempts[1].review,
      created_at_ms=s.attempts[1].created_at_ms,
      started_at_ms=Some(1L),
      finished_at_ms=s.attempts[1].finished_at_ms,
      updated_at_ms=s.attempts[1].updated_at_ms,
    ),
  ]
  let snapshot = { ..s, tasks, attempts, }
  let result = recover_snapshot(snapshot, at_ms=200L).unwrap()
  assert_eq(result.snapshot.revision, 18L)
  assert_eq(result.events.length(), 4)
  for task in result.snapshot.tasks {
    assert_eq(task.stage, @domain.Suspended)
    assert_eq(task.updated_at_ms, 200L)
  }
  for attempt in result.snapshot.attempts {
    assert_eq(attempt.status, @domain.Interrupted)
    assert_eq(attempt.finished_at_ms, Some(200L))
    assert_eq(attempt.updated_at_ms, 200L)
  }
  assert_eq(snapshot.revision, 17L)
  assert_eq(snapshot.tasks[0].stage, @domain.Running)
  assert_eq(recover_snapshot(result.snapshot, at_ms=300L).unwrap().events, [])
}

///|
test "recovery leaves every non-running stage and status unchanged and detached" {
  let s = fixture()
  for
    stage in [
      @domain.BoardStage::Created,
      Refining,
      Ready,
      Review,
      Done,
      Suspended,
    ] {
    for
      status in [
        @domain.AttemptStatus::Queued,
        Succeeded,
        Failed,
        Cancelled,
        Interrupted,
      ] {
      let snapshot : @domain.BoardStateSnapshot = {
        revision: 9223372036854775807L,
        tasks: [
          @domain.BoardTask::from_record(
            id=s.tasks[0].id,
            title=s.tasks[0].title,
            description=s.tasks[0].description,
            stage~,
            priority=s.tasks[0].priority,
            definition_of_done=s.tasks[0].definition_of_done,
            dependencies=s.tasks[0].dependencies,
            created_at_ms=s.tasks[0].created_at_ms,
            updated_at_ms=s.tasks[0].updated_at_ms,
            ready_since_ms=s.tasks[0].ready_since_ms,
          ),
          s.tasks[1],
        ],
        attempts: [
          @domain.Attempt::from_record(
            id=s.attempts[0].id,
            task_id=s.attempts[0].task_id,
            kind=s.attempts[0].kind,
            status~,
            review=s.attempts[0].review,
            created_at_ms=s.attempts[0].created_at_ms,
            started_at_ms=s.attempts[0].started_at_ms,
            finished_at_ms=s.attempts[0].finished_at_ms,
            updated_at_ms=s.attempts[0].updated_at_ms,
          ),
          s.attempts[1],
        ],
      }
      let result = recover_snapshot(snapshot, at_ms=100L).unwrap()
      assert_eq(result.snapshot, snapshot)
      assert_eq(result.events, [])
      result.snapshot.tasks[0].definition_of_done.clear()
      result.snapshot.tasks[0].dependencies.clear()
      assert_eq(snapshot.tasks[0].definition_of_done, ["tested", "documented"])
      assert_eq(snapshot.tasks[0].dependencies, [tid("b")])
    }
  }
}

///|
priv struct RejectingStore {
  failure : BoardStoreError
  fail_load : Bool
  calls : Ref[Int]
}

///|
impl BoardStore for RejectingStore with fn load(self) {
  if self.fail_load {
    Err(self.failure)
  } else {
    Ok({ snapshot: fixture(), journal: [], })
  }
}

///|
impl BoardStore for RejectingStore with fn persist(self, _, _) {
  self.calls.val = self.calls.val + 1
  Err(self.failure)
}

///|
async test "helper forwards load persist and invalid time errors without speculative results" {
  let error = Io("unavailable")
  let calls = Ref(0)
  let store = RejectingStore::{ failure: error, fail_load: true, calls, }
  assert_eq(load_recover_persist(store, at_ms=123L).map(_ => ()), Err(error))
  assert_eq(calls.val, 0)
  let store = RejectingStore::{ failure: error, fail_load: false, calls, }
  invalid(load_recover_persist(store, at_ms=-1L))
  assert_eq(calls.val, 0)
  assert_eq(load_recover_persist(store, at_ms=123L).map(_ => ()), Err(error))
  assert_eq(calls.val, 1)
}

///|
test "domain conversion includes every attempt field and full review lifecycle" {
  let state = @domain.BoardState::BoardState()
  let commands : Array[@domain.BoardCommand] = [
    CreateTask(
      id=tid("a"),
      title="a",
      description="",
      priority=Normal,
      definition_of_done=[],
      dependencies=[],
      at_ms=1L,
      expected_revision=0L,
    ),
    QueueAttempt(
      id=aid("x"),
      task=tid("a"),
      kind=Review,
      at_ms=2L,
      expected_revision=1L,
    ),
    StartAttempt(id=aid("x"), at_ms=3L, expected_revision=2L),
    RecordReview(
      id=aid("x"),
      decision=ChangesRequested,
      at_ms=4L,
      expected_revision=3L,
    ),
    FinishAttempt(id=aid("x"), outcome=Failed, at_ms=5L, expected_revision=4L),
  ]
  let mut state = state
  for command in commands {
    state = @domain.BoardDomain::propose(state, command).unwrap().next_state
  }
  let source = state.snapshot()
  let result = source.copy_detached()
  assert_eq(result.revision, 5L)
  assert_eq(result.attempts, [
    @domain.Attempt::from_record(
      id=aid("x"),
      task_id=tid("a"),
      kind=@domain.Review,
      status=@domain.Failed,
      review=Some(@domain.ChangesRequested),
      created_at_ms=2L,
      started_at_ms=Some(3L),
      finished_at_ms=Some(5L),
      updated_at_ms=5L,
    ),
  ])
  source.attempts.clear()
  assert_eq(result.attempts.length(), 1)
  assert_eq(decode_snapshot(encode_snapshot(result).unwrap()), Ok(result))
}

///|
test "strict nested duplicate fields escaped keys and event duplicate fields rejected" {
  let duplicate = "{\"schema_version\":1,\"type\":\"TaskCreated\",\"id\":\"a\",\"id\":\"b\",\"at_ms\":\"0\"}"
  invalid(decode_event(duplicate))
  invalid(decode_journal_events(duplicate + "\n"))
  invalid(decode_journal_events(duplicate))
  let valid = encode_snapshot(fixture()).unwrap()
  let nested = valid.replace(
    old="\"title\":",
    new="\"title\":\"duplicate\",\"title\":",
  )
  invalid(decode_snapshot(nested))
  assert_eq(
    decode_event(
      "{\"schema_version\":1,\"type\":\"TaskCreated\",\"id\":\"escaped \\\" string: { }\",\"at_ms\":\"0\"}",
    ),
    Ok(@domain.TaskCreated(id=tid("escaped \" string: { }"), at_ms=0L)),
  )
}
