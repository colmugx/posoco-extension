///|
fn restore_seed() -> @domain.BoardState {
  let state = @domain.BoardState::BoardState()
  let created = @domain.BoardDomain::propose(
    state,
    @domain.CreateTask(
      id=@domain.BoardTaskId("task"),
      title="restore me",
      description="durable board",
      priority=@domain.High,
      definition_of_done=["done"],
      dependencies=[],
      at_ms=10L,
      expected_revision=0L,
    ),
  ).unwrap()
  let refining = @domain.BoardDomain::propose(
    created.next_state,
    @domain.MoveTask(
      id=@domain.BoardTaskId("task"),
      to=@domain.Refining,
      at_ms=20L,
      expected_revision=1L,
    ),
  ).unwrap()
  let ready = @domain.BoardDomain::propose(
    refining.next_state,
    @domain.MoveTask(
      id=@domain.BoardTaskId("task"),
      to=@domain.Ready,
      at_ms=30L,
      expected_revision=2L,
    ),
  ).unwrap()
  let queued = @domain.BoardDomain::propose(
    ready.next_state,
    @domain.QueueAttempt(
      id=@domain.AttemptId("attempt"),
      task=@domain.BoardTaskId("task"),
      kind=@domain.Execute,
      at_ms=40L,
      expected_revision=3L,
    ),
  ).unwrap()
  @domain.BoardDomain::propose(
    queued.next_state,
    @domain.StartAttempt(
      id=@domain.AttemptId("attempt"),
      at_ms=50L,
      expected_revision=4L,
    ),
  ).unwrap().next_state
}

///|
fn restored_task(
  id~ : String,
  title? : String = "task",
  created_at_ms? : Int64 = 1L,
  updated_at_ms? : Int64 = 1L,
  definition_of_done? : Array[String] = [],
  dependencies? : Array[@domain.BoardTaskId] = [],
) -> @domain.BoardTask {
  @domain.BoardTask::from_record(
    id=@domain.BoardTaskId(id),
    title~,
    description="",
    stage=@domain.Created,
    priority=@domain.Normal,
    definition_of_done~,
    dependencies~,
    created_at_ms~,
    updated_at_ms~,
    ready_since_ms=None,
  )
}

///|
fn restored_attempt(
  id~ : String,
  task~ : String,
  created_at_ms? : Int64 = 1L,
  updated_at_ms? : Int64 = 1L,
) -> @domain.Attempt {
  @domain.Attempt::from_record(
    id=@domain.AttemptId(id),
    task_id=@domain.BoardTaskId(task),
    kind=@domain.Execute,
    status=@domain.Queued,
    review=None,
    created_at_ms~,
    started_at_ms=None,
    finished_at_ms=None,
    updated_at_ms~,
  )
}

///|
fn restored_snapshot(
  revision? : Int64 = 0L,
  tasks~ : Array[@domain.BoardTask],
  attempts? : Array[@domain.Attempt] = [],
) -> @domain.BoardStateSnapshot {
  { revision, tasks, attempts, }
}

///|
/// `BoardState` is encapsulated (no Eq/Debug), so outcomes are compared
/// through the revision, the queries or the typed rejection alone.
fn restored_rejection(
  snapshot : @domain.BoardStateSnapshot,
) -> @domain.BoardError raise {
  match @domain.BoardState::from_snapshot(snapshot) {
    Err(error) => error
    Ok(_) => fail("expected from_snapshot to reject")
  }
}

///|
test "from_snapshot restores the exact revision without a mutation bump" {
  let snapshot = restore_seed().snapshot()
  assert_eq(snapshot.revision, 5L)
  let restored = match @domain.BoardState::from_snapshot(snapshot) {
    Ok(state) => state
    Err(error) => fail("expected restore to succeed, got \{Repr(error)}")
  }
  assert_eq(restored.revision(), 5L)
  assert_eq(restored.tasks(), snapshot.tasks)
  assert_eq(restored.attempts(), snapshot.attempts)
  // The restored revision is exactly the next command's expectation: no
  // restoration event or bump happened.
  let accepted = @domain.BoardDomain::propose(
    restored,
    @domain.MoveTask(
      id=@domain.BoardTaskId("task"),
      to=@domain.Refining,
      at_ms=60L,
      expected_revision=5L,
    ),
  ).unwrap()
  assert_eq(accepted.next_state.revision(), 6L)
  assert_eq(accepted.events.length(), 1)
}

///|
test "from_snapshot roundtrips a canonical snapshot" {
  let snapshot = restore_seed().snapshot()
  let restored = match @domain.BoardState::from_snapshot(snapshot) {
    Ok(state) => state
    Err(error) => fail("expected restore to succeed, got \{Repr(error)}")
  }
  assert_eq(restored.snapshot(), snapshot)
}

///|
test "from_snapshot is deeply detached from the input snapshot" {
  let snapshot = restore_seed().snapshot()
  let restored = match @domain.BoardState::from_snapshot(snapshot) {
    Ok(state) => state
    Err(error) => fail("expected restore to succeed, got \{Repr(error)}")
  }
  let task = snapshot.tasks[0]
  task.dependencies.push(task.id)
  task.definition_of_done.clear()
  snapshot.tasks.clear()
  snapshot.tasks.push(task)
  snapshot.attempts.clear()
  assert_eq(restored.revision(), 5L)
  assert_eq(restored.tasks().length(), 1)
  assert_eq(restored.tasks()[0].dependencies, [])
  assert_eq(restored.tasks()[0].definition_of_done, ["done"])
  assert_eq(restored.attempts().length(), 1)
}

///|
test "from_snapshot accepts the empty board" {
  let restored = match
    @domain.BoardState::from_snapshot(restored_snapshot(revision=7L, tasks=[])) {
    Ok(state) => state
    Err(error) => fail("expected restore to succeed, got \{Repr(error)}")
  }
  assert_eq(restored.revision(), 7L)
  assert_eq(restored.tasks(), [])
  assert_eq(restored.attempts(), [])
}

///|
test "from_snapshot rejects malformed records" {
  assert_eq(
    restored_rejection(restored_snapshot(revision=-1L, tasks=[])),
    @domain.InvalidInput(reason="revision must not be negative"),
  )
  assert_eq(
    restored_rejection(restored_snapshot(tasks=[restored_task(id="")])),
    @domain.InvalidInput(reason="task id must not be empty"),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[restored_task(id="t", title="")]),
    ),
    @domain.InvalidInput(reason="title must not be empty"),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[
        restored_task(id="t", definition_of_done=["done", ""]),
      ]),
    ),
    @domain.InvalidInput(reason="definition_of_done items must not be empty"),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[
        restored_task(id="t", dependencies=[@domain.BoardTaskId("")]),
      ]),
    ),
    @domain.InvalidInput(reason="dependency id must not be empty"),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[restored_task(id="t", created_at_ms=-5L)]),
    ),
    @domain.InvalidInput(reason="created_at_ms must not be negative"),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[restored_task(id="t", updated_at_ms=-5L)]),
    ),
    @domain.InvalidInput(reason="updated_at_ms must not be negative"),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[restored_task(id="holder")], attempts=[
        restored_attempt(id="a", task="holder", created_at_ms=-5L),
      ]),
    ),
    @domain.InvalidInput(reason="created_at_ms must not be negative"),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[restored_task(id="holder")], attempts=[
        restored_attempt(id="a", task="holder", updated_at_ms=-5L),
      ]),
    ),
    @domain.InvalidInput(reason="updated_at_ms must not be negative"),
  )
}

///|
test "from_snapshot rejects duplicate ids and broken attempt references" {
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[restored_task(id="dup"), restored_task(id="dup")]),
    ),
    @domain.DuplicateTask(task=@domain.BoardTaskId("dup")),
  )
  let holder = restored_task(id="holder")
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[holder], attempts=[
        restored_attempt(id="dup", task="holder"),
        restored_attempt(id="dup", task="holder"),
      ]),
    ),
    @domain.DuplicateAttempt(attempt=@domain.AttemptId("dup")),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[holder], attempts=[
        restored_attempt(id="a", task="ghost"),
      ]),
    ),
    @domain.TaskMissing(task=@domain.BoardTaskId("ghost")),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[restored_task(id="")], attempts=[]),
    ),
    @domain.InvalidInput(reason="task id must not be empty"),
  )
}

///|
test "from_snapshot rejects broken dependency graphs" {
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[
        restored_task(id="a", dependencies=[@domain.BoardTaskId("ghost")]),
      ]),
    ),
    @domain.DependencyMissing(
      task=@domain.BoardTaskId("a"),
      dependency=@domain.BoardTaskId("ghost"),
    ),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[
        restored_task(id="a", dependencies=[@domain.BoardTaskId("a")]),
      ]),
    ),
    @domain.SelfDependency(task=@domain.BoardTaskId("a")),
  )
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[
        restored_task(id="a", dependencies=[
          @domain.BoardTaskId("b"),
          @domain.BoardTaskId("b"),
        ]),
        restored_task(id="b"),
      ]),
    ),
    @domain.DuplicateDependency(
      task=@domain.BoardTaskId("a"),
      dependency=@domain.BoardTaskId("b"),
    ),
  )
  // DFS from a in snapshot task order visits a -> b -> c -> a.
  assert_eq(
    restored_rejection(
      restored_snapshot(tasks=[
        restored_task(id="a", dependencies=[@domain.BoardTaskId("b")]),
        restored_task(id="b", dependencies=[@domain.BoardTaskId("c")]),
        restored_task(id="c", dependencies=[@domain.BoardTaskId("a")]),
      ]),
    ),
    @domain.DependencyCycle(cycle=[
      @domain.BoardTaskId("a"),
      @domain.BoardTaskId("b"),
      @domain.BoardTaskId("c"),
    ]),
  )
}
