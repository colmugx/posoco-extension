///|
fn tid(s : String) -> BoardTaskId {
  BoardTaskId::BoardTaskId(s)
}

///|
fn aid(s : String) -> AttemptId {
  AttemptId::AttemptId(s)
}

///|
fn create_cmd(
  id : String,
  rev : Int64,
  at? : Int64 = 1000L,
  deps? : Array[BoardTaskId] = [],
  dod? : Array[String] = [],
) -> BoardCommand {
  CreateTask(
    id=tid(id),
    title="task \{id}",
    description="desc \{id}",
    priority=Normal,
    definition_of_done=dod,
    dependencies=deps,
    at_ms=at,
    expected_revision=rev,
  )
}

///|
fn move_cmd(
  id : String,
  rev : Int64,
  to : BoardStage,
  at? : Int64 = 2000L,
) -> BoardCommand {
  MoveTask(id=tid(id), to~, at_ms=at, expected_revision=rev)
}

///|
fn accept(state : BoardState, command : BoardCommand) -> BoardProposal raise {
  match BoardDomain::propose(state, command) {
    Ok(proposal) => proposal
    Err(_) => fail("expected the command to be accepted")
  }
}

///|
fn rejection_of(state : BoardState, command : BoardCommand) -> BoardError raise {
  match BoardDomain::propose(state, command) {
    Ok(_) => fail("expected the command to be rejected")
    Err(error) => error
  }
}

///|
/// Canonical reachable path to each stage, committed on one task with
/// distinct timestamps so Ready entry/exit stamps are observable.
fn path_to(stage : BoardStage) -> Array[BoardStage] {
  match stage {
    Created => []
    Refining => [Refining]
    Ready => [Refining, Ready]
    Running => [Refining, Ready, Running]
    Review => [Refining, Ready, Running, Review]
    Done => [Refining, Ready, Running, Review, Done]
    Suspended => [Suspended]
  }
}

///|
fn task_at(stage : BoardStage) -> BoardState raise {
  let state = BoardState::BoardState()
  let mut revision = 0L
  let mut at = 1000L
  let proposal = accept(state, create_cmd("t", revision, at~))
  revision += 1L
  let mut state = proposal.next_state
  for step in path_to(stage) {
    at += 100L
    let proposal = accept(state, move_cmd("t", revision, step, at~))
    revision += 1L
    state = proposal.next_state
  }
  state
}

///|
test "create task lands on the created stage and bumps revision once" {
  let state = BoardState::BoardState()
  assert_eq(state.revision(), 0L)
  let proposal = accept(state, create_cmd("t1", 0L, at=1000L))
  assert_eq(state.revision(), 0L)
  assert_eq(proposal.events, [TaskCreated(id=tid("t1"), at_ms=1000L)])
  let next = proposal.next_state
  assert_eq(next.revision(), 1L)
  let task = next.task(tid("t1")).unwrap()
  assert_eq(task.id, tid("t1"))
  assert_eq(task.title, "task t1")
  assert_eq(task.description, "desc t1")
  assert_eq(task.stage, Created)
  assert_eq(task.priority, Normal)
  assert_eq(task.definition_of_done, [])
  assert_eq(task.dependencies, [])
  assert_eq(task.created_at_ms, 1000L)
  assert_eq(task.updated_at_ms, 1000L)
  assert_eq(task.ready_since_ms, None)
  assert_eq(next.attempt(aid("a1")), None)
}

///|
test "central fsm accepts exactly the baseline transitions" {
  let edges : Array[(BoardStage, BoardStage)] = [
    (Created, Refining),
    (Created, Suspended),
    (Refining, Ready),
    (Refining, Suspended),
    (Ready, Running),
    (Ready, Refining),
    (Ready, Suspended),
    (Running, Review),
    (Running, Suspended),
    (Review, Done),
    (Review, Ready),
    (Review, Refining),
    (Review, Suspended),
    (Done, Refining),
    (Suspended, Created),
    (Suspended, Refining),
    (Suspended, Ready),
  ]
  for (from, to) in edges {
    let state = task_at(from)
    let revision = state.revision()
    let proposal = accept(state, move_cmd("t", revision, to, at=9000L))
    let task = proposal.next_state.task(tid("t")).unwrap()
    assert_eq(task.stage, to)
    assert_eq(proposal.next_state.revision(), revision + 1L)
    assert_eq(proposal.events, [
      TaskStageChanged(id=tid("t"), from~, to~, at_ms=9000L),
    ])
  }
}

///|
test "central fsm rejects moves outside the table" {
  let rejected : Array[(BoardStage, BoardStage)] = [
    (Created, Created),
    (Created, Ready),
    (Created, Running),
    (Created, Review),
    (Created, Done),
    (Refining, Created),
    (Refining, Running),
    (Refining, Review),
    (Refining, Done),
    (Refining, Refining),
    (Ready, Created),
    (Ready, Review),
    (Ready, Done),
    (Ready, Ready),
    (Running, Created),
    (Running, Refining),
    (Running, Ready),
    (Running, Done),
    (Running, Running),
    (Review, Created),
    (Review, Running),
    (Review, Review),
    (Done, Created),
    (Done, Ready),
    (Done, Running),
    (Done, Review),
    (Done, Done),
    (Suspended, Running),
    (Suspended, Review),
    (Suspended, Done),
    (Suspended, Suspended),
  ]
  for (from, to) in rejected {
    let state = task_at(from)
    let revision = state.revision()
    assert_eq(
      rejection_of(state, move_cmd("t", revision, to, at=9000L)),
      InvalidTransition(from~, to~),
    )
    let task = state.task(tid("t")).unwrap()
    assert_eq(task.stage, from)
    assert_eq(state.revision(), revision)
  }
}

///|
test "entering ready stamps ready_since and leaving clears it" {
  let state = task_at(Refining)
  let revision = state.revision()
  let entering = accept(state, move_cmd("t", revision, Ready, at=7000L))
  let ready = entering.next_state.task(tid("t")).unwrap()
  assert_eq(ready.stage, Ready)
  assert_eq(ready.ready_since_ms, Some(7000L))
  let leaving = accept(
    entering.next_state,
    move_cmd("t", revision + 1L, Running, at=8000L),
  )
  let running = leaving.next_state.task(tid("t")).unwrap()
  assert_eq(running.stage, Running)
  assert_eq(running.ready_since_ms, None)
  let resuspending = accept(
    leaving.next_state,
    move_cmd("t", revision + 2L, Suspended, at=8500L),
  )
  assert_eq(
    resuspending.next_state.task(tid("t")).unwrap().ready_since_ms,
    None,
  )
}

///|
test "revision conflict reports expected and actual and keeps state" {
  let state = accept(BoardState::BoardState(), create_cmd("t1", 0L)).next_state
  match BoardDomain::propose(state, create_cmd("t2", 0L)) {
    Err(RevisionConflict(expected~, actual~)) => {
      assert_eq(expected, 0L)
      assert_eq(actual, 1L)
    }
    _ => fail("expected a revision conflict")
  }
  assert_eq(state.revision(), 1L)
  assert_eq(state.task(tid("t2")), None)
  assert_eq(state.tasks().length(), 1)
}

///|
test "duplicate task and attempt ids are rejected" {
  let state = accept(BoardState::BoardState(), create_cmd("t1", 0L)).next_state
  assert_eq(
    rejection_of(state, create_cmd("t1", 1L)),
    DuplicateTask(task=tid("t1")),
  )
  let queued = accept(
    state,
    QueueAttempt(
      id=aid("a1"),
      task=tid("t1"),
      kind=Execute,
      at_ms=1500L,
      expected_revision=1L,
    ),
  )
  assert_eq(
    rejection_of(
      queued.next_state,
      QueueAttempt(
        id=aid("a1"),
        task=tid("t1"),
        kind=Discuss,
        at_ms=1600L,
        expected_revision=2L,
      ),
    ),
    DuplicateAttempt(attempt=aid("a1")),
  )
}

///|
test "dependency commands reject missing self duplicate and cycle" {
  let state = accept(BoardState::BoardState(), create_cmd("a", 0L)).next_state
  let state = accept(state, create_cmd("b", 1L)).next_state
  let state = accept(state, create_cmd("c", 2L)).next_state
  assert_eq(
    rejection_of(state, create_cmd("d", 3L, deps=[tid("ghost")])),
    DependencyMissing(task=tid("d"), dependency=tid("ghost")),
  )
  assert_eq(
    rejection_of(state, create_cmd("d", 3L, deps=[tid("d")])),
    SelfDependency(task=tid("d")),
  )
  assert_eq(
    rejection_of(
      state,
      SetDependencies(
        id=tid("a"),
        dependencies=[tid("b"), tid("b")],
        at_ms=5000L,
        expected_revision=3L,
      ),
    ),
    DuplicateDependency(task=tid("a"), dependency=tid("b")),
  )
  let ab = accept(
    state,
    SetDependencies(
      id=tid("a"),
      dependencies=[tid("b")],
      at_ms=5000L,
      expected_revision=3L,
    ),
  )
  let bc = accept(
    ab.next_state,
    SetDependencies(
      id=tid("b"),
      dependencies=[tid("c")],
      at_ms=5100L,
      expected_revision=4L,
    ),
  )
  match
    BoardDomain::propose(
      bc.next_state,
      SetDependencies(
        id=tid("c"),
        dependencies=[tid("a")],
        at_ms=5200L,
        expected_revision=5L,
      ),
    ) {
    Err(DependencyCycle(cycle~)) => assert_eq(cycle, [tid("a"), tid("b")])
    _ => fail("expected a dependency cycle")
  }
  // Acyclic graphs stay accepted, including diamonds.
  let state = accept(BoardState::BoardState(), create_cmd("a", 0L)).next_state
  let state = accept(state, create_cmd("b", 1L)).next_state
  let state = accept(state, create_cmd("c", 2L)).next_state
  let state = accept(
      state,
      SetDependencies(
        id=tid("b"),
        dependencies=[tid("a")],
        at_ms=5000L,
        expected_revision=3L,
      ),
    ).next_state
  let state = accept(
      state,
      SetDependencies(
        id=tid("c"),
        dependencies=[tid("a")],
        at_ms=5100L,
        expected_revision=4L,
      ),
    ).next_state
  let diamond = accept(
    state,
    SetDependencies(
      id=tid("a"),
      dependencies=[],
      at_ms=5200L,
      expected_revision=5L,
    ),
  )
  assert_eq(diamond.next_state.task(tid("b")).unwrap().dependencies, [tid("a")])
}

///|
test "ready entry does not require dependencies to be done" {
  let state = accept(BoardState::BoardState(), create_cmd("a", 0L)).next_state
  let state = accept(state, create_cmd("b", 1L, deps=[tid("a")])).next_state
  // "a" is still Created, never Done.
  let refining = accept(state, move_cmd("b", 2L, Refining, at=3000L))
  let ready = accept(refining.next_state, move_cmd("b", 3L, Ready, at=4000L))
  let task = ready.next_state.task(tid("b")).unwrap()
  assert_eq(task.stage, Ready)
  assert_eq(task.ready_since_ms, Some(4000L))
  assert_eq(task.dependencies, [tid("a")])
}

///|
test "tasks list in priority then creation then id order" {
  let mut state = BoardState::BoardState()
  let plan : Array[(String, BoardPriority, Int64)] = [
    ("n1", Normal, 100L),
    ("h1", High, 100L),
    ("c2", Critical, 200L),
    ("c1", Critical, 100L),
    ("n2", Normal, 100L),
  ]
  let mut revision = 0L
  for (id, priority, at) in plan {
    let command : BoardCommand = CreateTask(
      id=tid(id),
      title=id,
      description="",
      priority~,
      definition_of_done=[],
      dependencies=[],
      at_ms=at,
      expected_revision=revision,
    )
    state = accept(state, command).next_state
    revision += 1L
  }
  let order = state.tasks().map(task => task.id.value)
  assert_eq(order, ["c1", "c2", "h1", "n1", "n2"])
  let snapshot = state.snapshot()
  assert_eq(snapshot.revision, revision)
  assert_eq(snapshot.tasks.map(task => task.id.value), [
    "c1", "c2", "h1", "n1", "n2",
  ])
}

///|
test "updates change single fields and reject no-op updates" {
  let state = accept(
      BoardState::BoardState(),
      create_cmd("t1", 0L, at=1000L, dod=["write tests"]),
    ).next_state
  let updated = accept(
    state,
    UpdateTask(
      id=tid("t1"),
      title=Some("renamed"),
      description=None,
      priority=Some(High),
      definition_of_done=Some(["write tests", "ship"]),
      at_ms=6000L,
      expected_revision=1L,
    ),
  )
  assert_eq(updated.events, [TaskUpdated(id=tid("t1"), at_ms=6000L)])
  let task = updated.next_state.task(tid("t1")).unwrap()
  assert_eq(task.title, "renamed")
  assert_eq(task.description, "desc t1")
  assert_eq(task.priority, High)
  assert_eq(task.definition_of_done, ["write tests", "ship"])
  assert_eq(task.updated_at_ms, 6000L)
  assert_eq(task.created_at_ms, 1000L)
  assert_eq(
    rejection_of(
      updated.next_state,
      UpdateTask(
        id=tid("t1"),
        title=None,
        description=None,
        priority=None,
        definition_of_done=None,
        at_ms=6100L,
        expected_revision=2L,
      ),
    ),
    InvalidInput(reason="update carries no changes"),
  )
  assert_eq(
    rejection_of(
      updated.next_state,
      UpdateTask(
        id=tid("ghost"),
        title=Some("x"),
        description=None,
        priority=None,
        definition_of_done=None,
        at_ms=6100L,
        expected_revision=2L,
      ),
    ),
    TaskMissing(task=tid("ghost")),
  )
}

///|
test "attempt lifecycle follows queued running terminal" {
  let state = accept(BoardState::BoardState(), create_cmd("t1", 0L)).next_state
  let queued = accept(
    state,
    QueueAttempt(
      id=aid("a1"),
      task=tid("t1"),
      kind=Execute,
      at_ms=1500L,
      expected_revision=1L,
    ),
  )
  assert_eq(queued.events, [
    AttemptQueued(id=aid("a1"), task_id=tid("t1"), kind=Execute, at_ms=1500L),
  ])
  let attempt = queued.next_state.attempt(aid("a1")).unwrap()
  assert_eq(attempt.status, Queued)
  assert_eq(attempt.review, None)
  assert_eq(attempt.created_at_ms, 1500L)
  assert_eq(attempt.started_at_ms, None)
  assert_eq(attempt.finished_at_ms, None)
  let started = accept(
    queued.next_state,
    StartAttempt(id=aid("a1"), at_ms=1600L, expected_revision=2L),
  )
  assert_eq(started.events, [
    AttemptStarted(id=aid("a1"), task_id=tid("t1"), at_ms=1600L),
  ])
  let running = started.next_state.attempt(aid("a1")).unwrap()
  assert_eq(running.status, Running)
  assert_eq(running.started_at_ms, Some(1600L))
  assert_eq(running.finished_at_ms, None)
  assert_eq(running.updated_at_ms, 1600L)
  let finished = accept(
    started.next_state,
    FinishAttempt(
      id=aid("a1"),
      outcome=Succeeded,
      at_ms=1700L,
      expected_revision=3L,
    ),
  )
  assert_eq(finished.events, [
    AttemptFinished(
      id=aid("a1"),
      task_id=tid("t1"),
      outcome=Succeeded,
      at_ms=1700L,
    ),
  ])
  let done = finished.next_state.attempt(aid("a1")).unwrap()
  assert_eq(done.status, Succeeded)
  // Finish retains the start stamp and sets only the finish stamp.
  assert_eq(done.started_at_ms, Some(1600L))
  assert_eq(done.finished_at_ms, Some(1700L))
  assert_eq(done.updated_at_ms, 1700L)
  let state = finished.next_state
  assert_eq(state.attempts().length(), 1)
  // Tasks stay untouched by attempt work in S3A; stage coupling is S4.
  assert_eq(state.task(tid("t1")).unwrap().stage, Created)
}

///|
test "attempt fsm rejects illegal status moves" {
  let state = accept(BoardState::BoardState(), create_cmd("t1", 0L)).next_state
  let queue = QueueAttempt(
    id=aid("a1"),
    task=tid("t1"),
    kind=Execute,
    at_ms=1500L,
    expected_revision=1L,
  )
  let queued = accept(state, queue).next_state
  // Finish before start.
  assert_eq(
    rejection_of(
      queued,
      FinishAttempt(
        id=aid("a1"),
        outcome=Failed,
        at_ms=1550L,
        expected_revision=2L,
      ),
    ),
    InvalidAttemptTransition(attempt=aid("a1"), from=Queued, to=Failed),
  )
  let started = accept(
      queued,
      StartAttempt(id=aid("a1"), at_ms=1600L, expected_revision=2L),
    ).next_state
  // Double start.
  assert_eq(
    rejection_of(
      started,
      StartAttempt(id=aid("a1"), at_ms=1650L, expected_revision=3L),
    ),
    InvalidAttemptTransition(attempt=aid("a1"), from=Running, to=Running),
  )
  let finished = accept(
      started,
      FinishAttempt(
        id=aid("a1"),
        outcome=Cancelled,
        at_ms=1700L,
        expected_revision=3L,
      ),
    ).next_state
  // Terminal outcomes are final.
  assert_eq(
    rejection_of(
      finished,
      StartAttempt(id=aid("a1"), at_ms=1750L, expected_revision=4L),
    ),
    InvalidAttemptTransition(attempt=aid("a1"), from=Cancelled, to=Running),
  )
  assert_eq(
    rejection_of(
      finished,
      FinishAttempt(
        id=aid("a1"),
        outcome=Interrupted,
        at_ms=1750L,
        expected_revision=4L,
      ),
    ),
    InvalidAttemptTransition(attempt=aid("a1"), from=Cancelled, to=Interrupted),
  )
  assert_eq(
    rejection_of(
      state,
      StartAttempt(id=aid("ghost"), at_ms=1800L, expected_revision=1L),
    ),
    AttemptMissing(attempt=aid("ghost")),
  )
  assert_eq(
    rejection_of(
      state,
      QueueAttempt(
        id=aid("a2"),
        task=tid("ghost"),
        kind=Review,
        at_ms=1800L,
        expected_revision=1L,
      ),
    ),
    TaskMissing(task=tid("ghost")),
  )
}

///|
test "review attempts start pending and accept one terminal decision" {
  let state = accept(BoardState::BoardState(), create_cmd("t1", 0L)).next_state
  let state = accept(
      state,
      QueueAttempt(
        id=aid("r1"),
        task=tid("t1"),
        kind=Review,
        at_ms=1500L,
        expected_revision=1L,
      ),
    ).next_state
  let started = accept(
    state,
    StartAttempt(id=aid("r1"), at_ms=1600L, expected_revision=2L),
  )
  assert_eq(
    started.next_state.attempt(aid("r1")).unwrap().review,
    Some(Pending),
  )
  let recorded = accept(
    started.next_state,
    RecordReview(
      id=aid("r1"),
      decision=ChangesRequested,
      at_ms=1700L,
      expected_revision=3L,
    ),
  )
  assert_eq(recorded.events, [
    ReviewRecorded(
      id=aid("r1"),
      task_id=tid("t1"),
      decision=ChangesRequested,
      at_ms=1700L,
    ),
  ])
  assert_eq(
    recorded.next_state.attempt(aid("r1")).unwrap().review,
    Some(ChangesRequested),
  )
  let state = recorded.next_state
  assert_eq(
    rejection_of(
      state,
      RecordReview(
        id=aid("r1"),
        decision=Approved,
        at_ms=1750L,
        expected_revision=4L,
      ),
    ),
    InvalidReviewTransition(
      attempt=aid("r1"),
      current=Some(ChangesRequested),
      requested=Approved,
    ),
  )
  // A fresh attempt cannot be reviewed before it runs.
  let state = accept(
      state,
      QueueAttempt(
        id=aid("r2"),
        task=tid("t1"),
        kind=Review,
        at_ms=1800L,
        expected_revision=4L,
      ),
    ).next_state
  assert_eq(
    rejection_of(
      state,
      RecordReview(
        id=aid("r2"),
        decision=Approved,
        at_ms=1850L,
        expected_revision=5L,
      ),
    ),
    InvalidReviewTransition(attempt=aid("r2"), current=None, requested=Approved),
  )
  assert_eq(
    rejection_of(
      state,
      RecordReview(
        id=aid("r2"),
        decision=Pending,
        at_ms=1850L,
        expected_revision=5L,
      ),
    ),
    InvalidInput(reason="only Approved or ChangesRequested can be recorded"),
  )
  // Execute attempts never carry review decisions.
  let state = accept(
      state,
      QueueAttempt(
        id=aid("e1"),
        task=tid("t1"),
        kind=Execute,
        at_ms=1900L,
        expected_revision=5L,
      ),
    ).next_state
  let state = accept(
      state,
      StartAttempt(id=aid("e1"), at_ms=1950L, expected_revision=6L),
    ).next_state
  assert_eq(state.attempt(aid("e1")).unwrap().review, None)
  assert_eq(
    rejection_of(
      state,
      RecordReview(
        id=aid("e1"),
        decision=Approved,
        at_ms=2000L,
        expected_revision=7L,
      ),
    ),
    InvalidInput(reason="review decisions require an attempt of kind Review"),
  )
}

///|
test "structurally invalid input is rejected before existence checks" {
  let state = accept(BoardState::BoardState(), create_cmd("t1", 0L)).next_state
  let checks : Array[(BoardCommand, String)] = []
  checks.push(
    (
      CreateTask(
        id=tid(""),
        title="x",
        description="",
        priority=Low,
        definition_of_done=[],
        dependencies=[],
        at_ms=1L,
        expected_revision=1L,
      ),
      "task id must not be empty",
    ),
  )
  checks.push(
    (create_cmd("t2", 1L, at=-1L), "created_at_ms must not be negative"),
  )
  checks.push(
    (
      CreateTask(
        id=tid("t3"),
        title="",
        description="",
        priority=Low,
        definition_of_done=[],
        dependencies=[],
        at_ms=1L,
        expected_revision=1L,
      ),
      "title must not be empty",
    ),
  )
  checks.push(
    (
      create_cmd("t4", 1L, dod=["ok", ""]),
      "definition_of_done items must not be empty",
    ),
  )
  checks.push(
    (create_cmd("t5", 1L, deps=[tid("")]), "dependency id must not be empty"),
  )
  checks.push(
    (move_cmd("t1", 1L, Review, at=-5L), "updated_at_ms must not be negative"),
  )
  checks.push(
    (
      QueueAttempt(
        id=aid(""),
        task=tid("t1"),
        kind=Execute,
        at_ms=1L,
        expected_revision=1L,
      ),
      "attempt id must not be empty",
    ),
  )
  checks.push(
    (
      QueueAttempt(
        id=aid("a1"),
        task=tid(""),
        kind=Execute,
        at_ms=1L,
        expected_revision=1L,
      ),
      "task id must not be empty",
    ),
  )
  for (command, reason) in checks {
    assert_eq(rejection_of(state, command), InvalidInput(reason~))
  }
}

///|
test "accepted proposals detach input state and command arrays" {
  let deps : Array[BoardTaskId] = []
  let dod : Array[String] = ["draft"]
  let state = BoardState::BoardState()
  let base = accept(state, create_cmd("a", 0L, at=1000L)).next_state
  let proposal = accept(base, create_cmd("b", 1L, at=2000L, deps~, dod~))
  deps.push(tid("a"))
  dod.push("late mutation")
  let task = proposal.next_state.task(tid("b")).unwrap()
  assert_eq(task.dependencies, [])
  assert_eq(task.definition_of_done, ["draft"])
  // The input state is untouched by the accepted successor.
  assert_eq(base.revision(), 1L)
  assert_eq(base.task(tid("b")), None)
  // Mutating arrays of a returned proposal does not change committed state.
  proposal.events.clear()
  assert_eq(proposal.next_state.revision(), 2L)
}

///|
test "rejected proposals leave the state byte-identical" {
  let state = task_at(Refining)
  let snapshot_before = state.snapshot()
  let _ = rejection_of(state, move_cmd("t", state.revision(), Done, at=9500L))
  let _ = rejection_of(state, create_cmd("t", state.revision()))
  assert_eq(state.snapshot(), snapshot_before)
}

///|
test "queries return deep copies that never alias committed state" {
  let state = accept(
      BoardState::BoardState(),
      create_cmd("t1", 0L, at=1000L, dod=["a", "b"], deps=[]),
    ).next_state
  let first = state.task(tid("t1")).unwrap()
  let second = state.task(tid("t1")).unwrap()
  first.definition_of_done.push("mutated")
  first.dependencies.push(tid("t1"))
  assert_eq(second.definition_of_done, ["a", "b"])
  assert_eq(second.dependencies, [])
  assert_eq(state.task(tid("t1")).unwrap().definition_of_done, ["a", "b"])
  let snapshot = state.snapshot()
  snapshot.tasks[0].definition_of_done.push("snapshot mutation")
  assert_eq(state.snapshot(), {
    revision: 1L,
    tasks: [
      {
        id: tid("t1"),
        title: "task t1",
        description: "desc t1",
        stage: Created,
        priority: Normal,
        definition_of_done: ["a", "b"],
        dependencies: [],
        created_at_ms: 1000L,
        updated_at_ms: 1000L,
        ready_since_ms: None,
      },
    ],
    attempts: [],
  })
}

///|
test "suspended tasks resume only into created refining or ready" {
  // Covered edge-by-edge in the FSM table tests; this pins one full
  // suspend/resume round trip end to end.
  let state = task_at(Suspended)
  let revision = state.revision()
  let resumed = accept(state, move_cmd("t", revision, Ready, at=9100L))
  let task = resumed.next_state.task(tid("t")).unwrap()
  assert_eq(task.stage, Ready)
  assert_eq(task.ready_since_ms, Some(9100L))
}

///|
test "command copy detaches array payloads from the caller" {
  let dod : Array[String] = ["draft"]
  let deps : Array[BoardTaskId] = [tid("a")]
  let command : BoardCommand = CreateTask(
    id=tid("t1"),
    title="t1",
    description="",
    priority=Normal,
    definition_of_done=dod,
    dependencies=deps,
    at_ms=1000L,
    expected_revision=0L,
  )
  let copy = command.copy_detached()
  dod.push("late")
  deps.push(tid("b"))
  match copy {
    CreateTask(definition_of_done=copy_dod, dependencies=copy_deps, ..) => {
      assert_eq(copy_dod, ["draft"])
      assert_eq(copy_deps, [tid("a")])
    }
    _ => fail("expected a create command")
  }
  // Array-free commands copy by value sharing only immutable fields.
  let move_command = move_cmd("t1", 1L, Ready, at=2000L)
  assert_eq(move_command.copy_detached(), move_command)
  let set_deps = SetDependencies(
    id=tid("t1"),
    dependencies=deps,
    at_ms=3000L,
    expected_revision=1L,
  )
  // A copy taken before the push is unaffected; one taken after sees the
  // push, which is exactly the hazard the pre-mailbox copy removes.
  deps.push(tid("c"))
  match set_deps.copy_detached() {
    SetDependencies(dependencies=copy_deps, ..) =>
      assert_eq(copy_deps, [tid("a"), tid("b"), tid("c")])
    _ => fail("expected a set-dependencies command")
  }
}

///|
test "set-dependencies event does not alias the caller array" {
  let state = accept(BoardState::BoardState(), create_cmd("a", 0L)).next_state
  let state = accept(state, create_cmd("b", 1L)).next_state
  let deps : Array[BoardTaskId] = [tid("b")]
  let proposal = accept(
    state,
    SetDependencies(
      id=tid("a"),
      dependencies=deps,
      at_ms=5000L,
      expected_revision=2L,
    ),
  )
  // Every other event carries only immutable scalars/ids; DependenciesSet
  // is the one array-bearing event and must carry a copy.
  deps.push(tid("b"))
  assert_eq(proposal.events, [
    DependenciesSet(id=tid("a"), dependencies=[tid("b")], at_ms=5000L),
  ])
  // The committed task list is equally detached (state-level copy).
  assert_eq(proposal.next_state.task(tid("a")).unwrap().dependencies, [tid("b")])
}

///|
test "review recording is independent of attempt finish" {
  let state = accept(BoardState::BoardState(), create_cmd("t1", 0L)).next_state
  let state = accept(
      state,
      QueueAttempt(
        id=aid("r1"),
        task=tid("t1"),
        kind=Review,
        at_ms=1500L,
        expected_revision=1L,
      ),
    ).next_state
  let state = accept(
      state,
      StartAttempt(id=aid("r1"), at_ms=1600L, expected_revision=2L),
    ).next_state
  // Finishing while the review is still Pending is legal and fabricates
  // no decision.
  let state = accept(
      state,
      FinishAttempt(
        id=aid("r1"),
        outcome=Succeeded,
        at_ms=1700L,
        expected_revision=3L,
      ),
    ).next_state
  let finished = state.attempt(aid("r1")).unwrap()
  assert_eq(finished.status, Succeeded)
  assert_eq(finished.review, Some(Pending))
  // A terminal attempt can no longer be reviewed.
  assert_eq(
    rejection_of(
      state,
      RecordReview(
        id=aid("r1"),
        decision=Approved,
        at_ms=1750L,
        expected_revision=4L,
      ),
    ),
    InvalidReviewTransition(
      attempt=aid("r1"),
      current=Some(Pending),
      requested=Approved,
    ),
  )
  // Conversely, recording first never changes the status; finishing stays
  // a separate command and retains the recorded decision.
  let state = accept(
      state,
      QueueAttempt(
        id=aid("r2"),
        task=tid("t1"),
        kind=Review,
        at_ms=1800L,
        expected_revision=4L,
      ),
    ).next_state
  let state = accept(
      state,
      StartAttempt(id=aid("r2"), at_ms=1900L, expected_revision=5L),
    ).next_state
  let state = accept(
      state,
      RecordReview(
        id=aid("r2"),
        decision=Approved,
        at_ms=1950L,
        expected_revision=6L,
      ),
    ).next_state
  let reviewed = state.attempt(aid("r2")).unwrap()
  assert_eq(reviewed.status, Running)
  assert_eq(reviewed.review, Some(Approved))
  let state = accept(
      state,
      FinishAttempt(
        id=aid("r2"),
        outcome=Failed,
        at_ms=2000L,
        expected_revision=7L,
      ),
    ).next_state
  let done = state.attempt(aid("r2")).unwrap()
  assert_eq(done.status, Failed)
  assert_eq(done.review, Some(Approved))
  assert_eq(done.started_at_ms, Some(1900L))
  assert_eq(done.finished_at_ms, Some(2000L))
}
