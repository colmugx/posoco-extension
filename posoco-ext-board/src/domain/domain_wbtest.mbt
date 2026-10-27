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
  at~ : Int64 = 1000L,
  deps~ : Array[BoardTaskId] = [],
  dod~ : Array[String] = [],
) -> BoardCommand {
  CreateTask(
    id=tid(id),
    title="task \{id}",
    description="desc \{id}",
    priority=Normal,
    definition_of_done=dod,
    dependencies=deps,
    user_story="",
    implementation_suggestions="",
    at_ms=at,
    expected_revision=rev,
  )
}

///|
fn move_cmd(
  id : String,
  rev : Int64,
  to : BoardStage,
  at~ : Int64 = 2000L,
) -> BoardCommand {
  MoveTask(id=tid(id), to~, at_ms=at, expected_revision=rev)
}

///|
fn delete_cmd(id : String, rev : Int64, at~ : Int64 = 3000L) -> BoardCommand {
  DeleteTask(id=tid(id), at_ms=at, expected_revision=rev)
}

///|
fn set_model_cmd(
  id : String,
  rev : Int64,
  model : ModelSelection?,
  at~ : Int64 = 4000L,
) -> BoardCommand {
  SetTaskModel(id=tid(id), model~, at_ms=at, expected_revision=rev)
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
    Verification => [Refining, Ready, Running, Verification]
    Review => [Refining, Ready, Running, Verification, Review]
    Done => [Refining, Ready, Running, Verification, Review, Done]
    Suspended => [Suspended]
    Cancelled => [Cancelled]
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
test "delete removes a refining ticket and records one event" {
  let state = task_at(Refining)
  let revision = state.revision()
  let proposal = accept(state, delete_cmd("t", revision))
  assert_eq(proposal.next_state.task(tid("t")), None)
  assert_eq(proposal.next_state.revision(), revision + 1L)
  assert_eq(proposal.events, [TaskDeleted(id=tid("t"), at_ms=3000L)])
}

///|
test "delete rejects a running ticket" {
  let state = task_at(Running)
  let error = rejection_of(state, delete_cmd("t", state.revision()))
  match error {
    InvalidInput(reason~) => assert_true(reason.contains("can be deleted"))
    _ => fail("expected a guarded deletion rejection")
  }
}

///|
test "delete rejects a ticket another task still depends on" {
  let state = task_at(Refining)
  let created = accept(
    state,
    create_cmd("child", state.revision(), deps=[tid("t")]),
  )
  let error = rejection_of(
    created.next_state,
    delete_cmd("t", created.next_state.revision()),
  )
  match error {
    InvalidInput(reason~) => assert_true(reason.contains("dependency"))
    _ => fail("expected a dependency rejection")
  }
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
    (Created, Cancelled),
    (Refining, Cancelled),
    (Ready, Cancelled),
    (Running, Cancelled),
    (Review, Cancelled),
    (Suspended, Cancelled),
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
    (Done, Cancelled),
    (Suspended, Running),
    (Suspended, Review),
    (Suspended, Done),
    (Suspended, Suspended),
    (Cancelled, Created),
    (Cancelled, Refining),
    (Cancelled, Ready),
    (Cancelled, Running),
    (Cancelled, Review),
    (Cancelled, Done),
    (Cancelled, Suspended),
    (Cancelled, Cancelled),
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
test "cancellation is reachable from every non-terminal stage" {
  let cancellable : Array[BoardStage] = [
    Created,
    Refining,
    Ready,
    Running,
    Review,
    Suspended,
  ]
  for from in cancellable {
    let state = task_at(from)
    let revision = state.revision()
    let proposal = accept(state, move_cmd("t", revision, Cancelled, at=9100L))
    let task = proposal.next_state.task(tid("t")).unwrap()
    assert_eq(task.stage, Cancelled)
    assert_eq(task.updated_at_ms, 9100L)
    // Cancelling out of Ready clears the stamp like any other exit.
    assert_eq(task.ready_since_ms, None)
    assert_eq(proposal.next_state.revision(), revision + 1L)
    assert_eq(proposal.events, [
      TaskStageChanged(id=tid("t"), from~, to=Cancelled, at_ms=9100L),
    ])
  }
}

///|
test "cancelled is terminal and done cannot be cancelled" {
  let state = task_at(Cancelled)
  let revision = state.revision()
  for
    to in [
      Created,
      Refining,
      Ready,
      Running,
      Review,
      Done,
      Suspended,
      Cancelled,
    ] {
    assert_eq(
      rejection_of(state, move_cmd("t", revision, to, at=9200L)),
      InvalidTransition(from=Cancelled, to~),
    )
  }
  assert_eq(state.task(tid("t")).unwrap().stage, Cancelled)
  assert_eq(state.revision(), revision)
  let done = task_at(Done)
  assert_eq(
    rejection_of(done, move_cmd("t", done.revision(), Cancelled, at=9200L)),
    InvalidTransition(from=Done, to=Cancelled),
  )
  assert_eq(done.task(tid("t")).unwrap().stage, Done)
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
      user_story="",
      implementation_suggestions="",
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
      user_story=None,
      implementation_suggestions=None,
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
        user_story=None,
        implementation_suggestions=None,
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
        user_story=None,
        implementation_suggestions=None,
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
        user_story="",
        implementation_suggestions="",
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
        user_story="",
        implementation_suggestions="",
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
        user_story: "",
        implementation_suggestions: "",
        assignments: [],
        model: None,
        review: None,
        review_feedback: None,
      },
    ],
    attempts: [],
    expansions: [],
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
    user_story="",
    implementation_suggestions="",
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

///|
test "set model pins and clears a ticket without changing its stage" {
  let state = task_at(Refining)
  let revision = state.revision()
  let model = ModelSelection::ModelSelection(
    slot="openai/gpt-5.2",
    effort=Some("high"),
  )
  let proposal = accept(state, set_model_cmd("t", revision, Some(model)))
  let task = proposal.next_state.task(tid("t")).unwrap()
  assert_eq(task.stage, Refining)
  assert_eq(task.model, Some(model))
  assert_eq(task.updated_at_ms, 4000L)
  assert_eq(proposal.next_state.revision(), revision + 1L)
  assert_eq(proposal.events, [
    TaskModelChanged(id=tid("t"), model=Some(model), at_ms=4000L),
  ])
  let cleared = accept(
    proposal.next_state,
    set_model_cmd("t", revision + 1L, None, at=4100L),
  )
  assert_eq(cleared.next_state.task(tid("t")).unwrap().model, None)
  assert_eq(cleared.events, [
    TaskModelChanged(id=tid("t"), model=None, at_ms=4100L),
  ])
}

///|
test "invalid or terminal model changes are rejected" {
  let state = task_at(Ready)
  assert_eq(
    rejection_of(
      state,
      set_model_cmd(
        "t",
        state.revision(),
        Some(ModelSelection::ModelSelection(slot="")),
      ),
    ),
    InvalidInput(reason="model slot must not be empty"),
  )
  let done = task_at(Done)
  assert_eq(
    rejection_of(
      done,
      set_model_cmd(
        "t",
        done.revision(),
        Some(ModelSelection::ModelSelection(slot="openai/gpt-5.2")),
      ),
    ),
    InvalidInput(reason="a terminal ticket cannot change its model"),
  )
}

///|
test "model survives a stage move" {
  let state = task_at(Ready)
  let model = ModelSelection::ModelSelection(slot="openai/gpt-5.2")
  let pinned = accept(state, set_model_cmd("t", state.revision(), Some(model)))
  let moved = accept(
    pinned.next_state,
    move_cmd("t", pinned.next_state.revision(), Running),
  )
  assert_eq(moved.next_state.task(tid("t")).unwrap().model, Some(model))
}

///|
fn review_report_fixture() -> ReviewReport {
  ReviewReport::from_record(
    outcome="Task carries a review report.",
    summary="Adds the durable schema only.",
    changes=["Task gains an optional review."],
    verification=[
      ReviewEvidence::from_record(
        kind=ReviewEvidenceKind::Test,
        label="domain suite",
        result=ReviewEvidenceResult::Passed,
        detail="43 tests",
      ),
    ],
    risks=["Nothing consumes the report yet."],
    notes=[],
    open_questions=["When does the runtime set it?"],
    artifacts=[
      ReviewArtifact::from_record(
        kind=ReviewArtifactKind::File,
        label="types.mbt",
        uri_or_digest="src/domain/types.mbt",
      ),
    ],
  )
}

///|
test "board task review is optional and survives a detached copy" {
  let base = BoardTask::from_record(
    id=tid("t1"),
    title="task t1",
    description="",
    stage=Created,
    priority=Normal,
    definition_of_done=[],
    dependencies=[],
    created_at_ms=1000L,
    updated_at_ms=1000L,
    ready_since_ms=None,
  )
  assert_eq(base.review, None)
  let changes : Array[String] = ["Task gains an optional review."]
  let report = review_report_fixture()
  let task = BoardTask::from_record(
    id=tid("t1"),
    title="task t1",
    description="",
    stage=Created,
    priority=Normal,
    definition_of_done=[],
    dependencies=[],
    created_at_ms=1000L,
    updated_at_ms=1000L,
    ready_since_ms=None,
    review=Some(report),
  )
  assert_eq(task.review.unwrap().changes, ["Task gains an optional review."])
  // The report is detached on construction: mutating the caller array after
  // the fact cannot reach the record.
  changes.push("late")
  assert_eq(task.review.unwrap().changes, ["Task gains an optional review."])
  let copy = task.copy_detached()
  assert_eq(copy, task)
  copy.review.unwrap().changes.push("copy only")
  copy.review.unwrap().artifacts.clear()
  assert_eq(task.review.unwrap().changes, ["Task gains an optional review."])
  assert_eq(task.review.unwrap().artifacts.length(), 1)
}

///|
fn review_cmd(
  id : String,
  rev : Int64,
  review : ReviewReport?,
  at~ : Int64 = 5000L,
) -> BoardCommand {
  SetReviewReport(id=tid(id), review~, at_ms=at, expected_revision=rev)
}

///|
/// Minimal report builder for the rejection cases: everything the fixture
/// carries is optional here except the two identifying texts.
fn report_with(
  outcome~ : String = "Task carries a review report.",
  summary~ : String = "Adds the durable write path.",
  verification~ : Array[ReviewEvidence] = [],
  artifacts~ : Array[ReviewArtifact] = [],
) -> ReviewReport {
  ReviewReport::from_record(
    outcome~,
    summary~,
    changes=[],
    verification~,
    risks=[],
    notes=[],
    open_questions=[],
    artifacts~,
  )
}

///|
test "set review report stores a detached report and emits one event" {
  let state = task_at(Running)
  let revision = state.revision()
  let report = review_report_fixture()
  let proposal = accept(state, review_cmd("t", revision, Some(report)))
  assert_eq(proposal.next_state.revision(), revision + 1L)
  assert_eq(proposal.events.length(), 1)
  assert_eq(proposal.events, [
    ReviewReportSet(id=tid("t"), review=Some(report), at_ms=5000L),
  ])
  let task = proposal.next_state.task(tid("t")).unwrap()
  assert_eq(task.review, Some(report))
  assert_eq(task.stage, Running)
  assert_eq(task.updated_at_ms, 5000L)
  // The committed record and the event are detached from the command input:
  // a caller that keeps mutating its arrays cannot reach either.
  report.changes.push("late")
  report.verification.clear()
  report.artifacts.clear()
  assert_eq(task.review.unwrap().changes, ["Task gains an optional review."])
  assert_eq(task.review.unwrap().verification.length(), 1)
  assert_eq(task.review.unwrap().artifacts.length(), 1)
  match proposal.events[0] {
    ReviewReportSet(review~, ..) => {
      assert_eq(review.unwrap().changes, ["Task gains an optional review."])
      assert_eq(review.unwrap().artifacts.length(), 1)
    }
    _ => fail("expected ReviewReportSet")
  }
}

///|
test "clearing a review report on a review ticket records one event" {
  let running = task_at(Running)
  let report = review_report_fixture()
  let set = accept(
    running,
    review_cmd("t", running.revision(), Some(report), at=1000L),
  )
  let cleared = accept(
    set.next_state,
    review_cmd("t", set.next_state.revision(), None, at=1100L),
  )
  assert_eq(cleared.next_state.revision(), running.revision() + 2L)
  assert_eq(cleared.events.length(), 1)
  assert_eq(cleared.events, [
    ReviewReportSet(id=tid("t"), review=None, at_ms=1100L),
  ])
  let task = cleared.next_state.task(tid("t")).unwrap()
  assert_eq(task.review, None)
  assert_eq(task.updated_at_ms, 1100L)
  // Clearing never touches the stage.
  assert_eq(task.stage, Running)
}

///|
test "review report is rejected outside running and review" {
  let report = report_with()
  for stage in [Created, Refining, Ready, Done, Suspended, Cancelled] {
    let state = task_at(stage)
    assert_eq(
      rejection_of(state, review_cmd("t", state.revision(), Some(report))),
      InvalidInput(
        reason="a review report requires a Running, Verification, or Review ticket",
      ),
    )
    assert_eq(
      rejection_of(state, review_cmd("t", state.revision(), None)),
      InvalidInput(
        reason="a review report requires a Running, Verification, or Review ticket",
      ),
    )
  }
}

///|
test "review report requires an outcome summary and labelled entries" {
  let state = task_at(Review)
  let revision = state.revision()
  let unlabelled_evidence = ReviewEvidence::from_record(
    kind=ReviewEvidenceKind::Test,
    label="",
    result=ReviewEvidenceResult::Passed,
    detail="",
  )
  let unlabelled_artifact = ReviewArtifact::from_record(
    kind=ReviewArtifactKind::File,
    label="",
    uri_or_digest="src/domain/propose.mbt",
  )
  let unaddressed_artifact = ReviewArtifact::from_record(
    kind=ReviewArtifactKind::File,
    label="propose.mbt",
    uri_or_digest="",
  )
  let cases : Array[(ReviewReport, BoardError)] = [
    (
      report_with(outcome=""),
      InvalidInput(reason="review outcome must not be empty"),
    ),
    (
      report_with(summary=""),
      InvalidInput(reason="review summary must not be empty"),
    ),
    (
      report_with(verification=[unlabelled_evidence]),
      InvalidInput(reason="review evidence label must not be empty"),
    ),
    (
      report_with(artifacts=[unlabelled_artifact]),
      InvalidInput(reason="review artifact label must not be empty"),
    ),
    (
      report_with(artifacts=[unaddressed_artifact]),
      InvalidInput(reason="review artifact uri_or_digest must not be empty"),
    ),
  ]
  for case in cases {
    let (report, expected) = case
    assert_eq(
      rejection_of(state, review_cmd("t", revision, Some(report))),
      expected,
    )
  }
  // A rejection never advances the revision.
  assert_eq(state.revision(), revision)
}

///|
test "review report validates the revision first and the task second" {
  let state = task_at(Running)
  let report = report_with(outcome="")
  assert_eq(
    rejection_of(state, review_cmd("t", state.revision() + 1L, Some(report))),
    RevisionConflict(expected=state.revision() + 1L, actual=state.revision()),
  )
  assert_eq(
    rejection_of(state, review_cmd("ghost", state.revision(), Some(report))),
    TaskMissing(task=tid("ghost")),
  )
  assert_eq(
    rejection_of(
      state,
      SetReviewReport(
        id=tid("ghost"),
        review=None,
        at_ms=-1L,
        expected_revision=state.revision(),
      ),
    ),
    TaskMissing(task=tid("ghost")),
  )
  assert_eq(
    rejection_of(state, review_cmd("t", state.revision(), Some(report), at=-1L)),
    InvalidInput(reason="updated_at_ms must not be negative"),
  )
}

///|
test "review report survives detached state copies" {
  let state = task_at(Running)
  let report = review_report_fixture()
  let proposal = accept(state, review_cmd("t", state.revision(), Some(report)))
  let copy = proposal.next_state.snapshot()
  copy.tasks[0].review.unwrap().changes.push("snapshot only")
  copy.tasks[0].review.unwrap().artifacts.clear()
  let stored = proposal.next_state.task(tid("t")).unwrap().review.unwrap()
  assert_eq(stored.changes, ["Task gains an optional review."])
  assert_eq(stored.artifacts.length(), 1)
}

///|
test "review report command and event copies detach the nested report" {
  let report = review_report_fixture()
  let command = review_cmd("t", 0L, Some(report))
  let detached = command.copy_detached()
  // Unrelated commands keep their identity; the report command re-copies.
  assert_eq(delete_cmd("t", 0L).copy_detached(), delete_cmd("t", 0L))
  report.changes.push("late")
  report.verification.clear()
  report.artifacts.clear()
  assert_eq(detached, review_cmd("t", 0L, Some(review_report_fixture())))
  match detached {
    SetReviewReport(review~, ..) => {
      assert_eq(review.unwrap().changes, ["Task gains an optional review."])
      assert_eq(review.unwrap().verification.length(), 1)
      assert_eq(review.unwrap().artifacts.length(), 1)
    }
    _ => fail("expected SetReviewReport")
  }
  let event = ReviewReportSet(
    id=tid("t"),
    review=Some(review_report_fixture()),
    at_ms=10L,
  )
  let event_copy = event.copy_detached()
  assert_eq(event_copy, event)
  match event_copy {
    ReviewReportSet(review~, ..) => {
      review.unwrap().changes.push("copy only")
      review.unwrap().artifacts.clear()
    }
    _ => fail("expected ReviewReportSet")
  }
  match event {
    ReviewReportSet(review~, ..) => {
      assert_eq(review.unwrap().changes, ["Task gains an optional review."])
      assert_eq(review.unwrap().artifacts.length(), 1)
    }
    _ => fail("expected ReviewReportSet")
  }
}

///|
/// A ticket at `stage` with one started Review attempt `r1` whose review is
/// still Pending — the only state a request-changes decision may act on.
fn request_changes_state(stage~ : BoardStage = Review) -> BoardState raise {
  let state = task_at(stage)
  let queued = accept(
    state,
    QueueAttempt(
      id=aid("r1"),
      task=tid("t"),
      kind=Review,
      at_ms=6000L,
      expected_revision=state.revision(),
    ),
  )
  accept(
    queued.next_state,
    StartAttempt(
      id=aid("r1"),
      at_ms=6100L,
      expected_revision=queued.next_state.revision(),
    ),
  ).next_state
}

///|
test "request changes folds the decision and the ticket feedback into one revision" {
  let state = request_changes_state()
  let revision = state.revision()
  assert_eq(state.task(tid("t")).unwrap().review_feedback, None)
  let proposal = accept(
    state,
    RequestChanges(
      id=aid("r1"),
      feedback="  add a regression test\n",
      at_ms=7000L,
      expected_revision=revision,
    ),
  )
  // One decision, one revision: the attempt and its ticket move together.
  assert_eq(proposal.next_state.revision(), revision + 1L)
  assert_eq(proposal.events, [
    ReviewChangesRequested(
      task_id=tid("t"),
      attempt_id=aid("r1"),
      feedback="add a regression test",
      at_ms=7000L,
    ),
  ])
  let attempt = proposal.next_state.attempt(aid("r1")).unwrap()
  assert_eq(attempt.review, Some(ChangesRequested))
  // Review independence: the decision never closes the attempt.
  assert_eq(attempt.status, Running)
  assert_eq(attempt.finished_at_ms, None)
  assert_eq(attempt.updated_at_ms, 7000L)
  let task = proposal.next_state.task(tid("t")).unwrap()
  assert_eq(task.stage, Ready)
  assert_eq(task.review_feedback, Some("add a regression test"))
  assert_eq(task.updated_at_ms, 7000L)
  // Entering Ready stamps the queue time exactly like an explicit move.
  assert_eq(task.ready_since_ms, Some(7000L))
  // The input state was never mutated.
  assert_eq(state.task(tid("t")).unwrap().stage, Review)
  assert_eq(state.task(tid("t")).unwrap().review_feedback, None)
  assert_eq(state.attempt(aid("r1")).unwrap().review, Some(Pending))
  // The ticket is immediately re-admissible and keeps the feedback.
  let mut reopened = proposal.next_state
  reopened = accept(
      reopened,
      move_cmd("t", reopened.revision(), Running, at=7100L),
    ).next_state
  let running = reopened.task(tid("t")).unwrap()
  assert_eq(running.stage, Running)
  assert_eq(running.ready_since_ms, None)
  assert_eq(running.review_feedback, Some("add a regression test"))
  // A second decision replaces the durable feedback instead of appending.
  let mut second = accept(
      reopened,
      move_cmd("t", reopened.revision(), Review, at=7200L),
    ).next_state
  let queued = accept(
      second,
      QueueAttempt(
        id=aid("r2"),
        task=tid("t"),
        kind=Review,
        at_ms=7300L,
        expected_revision=second.revision(),
      ),
    ).next_state
  second = accept(
      queued,
      StartAttempt(
        id=aid("r2"),
        at_ms=7400L,
        expected_revision=queued.revision(),
      ),
    ).next_state
  let replaced = accept(
      second,
      RequestChanges(
        id=aid("r2"),
        feedback="one more test",
        at_ms=7500L,
        expected_revision=second.revision(),
      ),
    ).next_state
  let updated = replaced.task(tid("t")).unwrap()
  assert_eq(updated.review_feedback, Some("one more test"))
  assert_eq(updated.stage, Ready)
  assert_eq(updated.ready_since_ms, Some(7500L))
  assert_eq(replaced.attempt(aid("r1")).unwrap().review, Some(ChangesRequested))
  assert_eq(replaced.attempt(aid("r2")).unwrap().review, Some(ChangesRequested))
}

///|
test "request changes rejects empty oversized and misdirected decisions" {
  let state = request_changes_state()
  let revision = state.revision()
  // Whitespace is not feedback.
  for feedback in ["", "   ", "\n\t "] {
    assert_eq(
      rejection_of(
        state,
        RequestChanges(
          id=aid("r1"),
          feedback~,
          at_ms=7000L,
          expected_revision=revision,
        ),
      ),
      InvalidInput(reason="review feedback must not be empty"),
    )
  }
  // The cap keeps one durable record bounded; exactly 4000 still fits.
  let oversized = StringBuilder()
  for i = 0; i < 4001; i = i + 1 {
    oversized.write_string("x")
  }
  assert_eq(
    rejection_of(
      state,
      RequestChanges(
        id=aid("r1"),
        feedback=oversized.to_string(),
        at_ms=7000L,
        expected_revision=revision,
      ),
    ),
    InvalidInput(reason="review feedback must be at most 4000 characters"),
  )
  let capped = StringBuilder()
  for i = 0; i < 4000; i = i + 1 {
    capped.write_string("x")
  }
  let accepted = accept(
    state,
    RequestChanges(
      id=aid("r1"),
      feedback=capped.to_string(),
      at_ms=7000L,
      expected_revision=revision,
    ),
  )
  assert_eq(
    accepted.next_state.task(tid("t")).unwrap().review_feedback
    .unwrap()
    .length(),
    4000,
  )
  // An unknown attempt is a typed miss, not a silent no-op.
  assert_eq(
    rejection_of(
      state,
      RequestChanges(
        id=aid("ghost"),
        feedback="fix it",
        at_ms=7000L,
        expected_revision=revision,
      ),
    ),
    AttemptMissing(attempt=aid("ghost")),
  )
  // Only a Review attempt carries a review decision.
  let discussing = accept(
      state,
      QueueAttempt(
        id=aid("d1"),
        task=tid("t"),
        kind=Discuss,
        at_ms=7000L,
        expected_revision=revision,
      ),
    ).next_state
  let discussing = accept(
      discussing,
      StartAttempt(
        id=aid("d1"),
        at_ms=7100L,
        expected_revision=discussing.revision(),
      ),
    ).next_state
  assert_eq(
    rejection_of(
      discussing,
      RequestChanges(
        id=aid("d1"),
        feedback="fix it",
        at_ms=7200L,
        expected_revision=discussing.revision(),
      ),
    ),
    InvalidInput(reason="requesting changes requires an attempt of kind Review"),
  )
  // A queued review attempt has no decision to change yet.
  let queued_only = accept(
      state,
      QueueAttempt(
        id=aid("q1"),
        task=tid("t"),
        kind=Review,
        at_ms=7000L,
        expected_revision=revision,
      ),
    ).next_state
  assert_eq(
    rejection_of(
      queued_only,
      RequestChanges(
        id=aid("q1"),
        feedback="fix it",
        at_ms=7100L,
        expected_revision=queued_only.revision(),
      ),
    ),
    InvalidReviewTransition(
      attempt=aid("q1"),
      current=None,
      requested=ChangesRequested,
    ),
  )
  // A terminal attempt can no longer be reviewed.
  let finished = accept(
      state,
      FinishAttempt(
        id=aid("r1"),
        outcome=Succeeded,
        at_ms=7000L,
        expected_revision=revision,
      ),
    ).next_state
  assert_eq(
    rejection_of(
      finished,
      RequestChanges(
        id=aid("r1"),
        feedback="fix it",
        at_ms=7100L,
        expected_revision=finished.revision(),
      ),
    ),
    InvalidReviewTransition(
      attempt=aid("r1"),
      current=Some(Pending),
      requested=ChangesRequested,
    ),
  )
  // A decision needs the ticket under review, not merely a review attempt.
  let not_under_review = request_changes_state(stage=Running)
  assert_eq(
    rejection_of(
      not_under_review,
      RequestChanges(
        id=aid("r1"),
        feedback="fix it",
        at_ms=7000L,
        expected_revision=not_under_review.revision(),
      ),
    ),
    InvalidInput(reason="requesting changes requires a ticket under review"),
  )
  // Rejections never advance the committed revision.
  assert_eq(state.revision(), revision)
  assert_eq(state.task(tid("t")).unwrap().review_feedback, None)
}

///|
test "story contract fields survive the Verification path" {
  let created = accept(BoardState::BoardState(), create_cmd("story", 0L)).next_state
  let shaped = accept(
      created,
      UpdateTask(
        id=tid("story"),
        title=None,
        description=Some("Detailed scope"),
        priority=Some(High),
        definition_of_done=Some(["Observable result"]),
        user_story=Some("As a user, I want a story, so that it can be built."),
        implementation_suggestions=Some("Start with the domain test."),
        at_ms=2000L,
        expected_revision=created.revision(),
      ),
    ).next_state
  let task = shaped.task(tid("story")).unwrap()
  assert_eq(
    task.user_story,
    "As a user, I want a story, so that it can be built.",
  )
  assert_eq(task.implementation_suggestions, "Start with the domain test.")
  let refining = accept(shaped, move_cmd("story", shaped.revision(), Refining)).next_state
  let ready = accept(refining, move_cmd("story", refining.revision(), Ready)).next_state
  let running = accept(ready, move_cmd("story", ready.revision(), Running)).next_state
  let verifying = accept(
      running,
      move_cmd("story", running.revision(), Verification),
    ).next_state
  assert_eq(verifying.task(tid("story")).unwrap().stage, Verification)
  let review = accept(
      verifying,
      move_cmd("story", verifying.revision(), Review),
    ).next_state
  assert_eq(review.task(tid("story")).unwrap().stage, Review)
}

///|
test "assign role stores unique stable slots and replaces one role" {
  let created = accept(BoardState::BoardState(), create_cmd("t1", 0L)).next_state
  let assigned = accept(
    created,
    AssignRole(
      id=tid("t1"),
      role=RD,
      member_id=" member-rd ",
      at_ms=2000L,
      expected_revision=1L,
    ),
  )
  assert_eq(assigned.next_state.task(tid("t1")).unwrap().assignments, [
    { role: RD, member_id: "member-rd", },
  ])
  let replaced = accept(
    assigned.next_state,
    AssignRole(
      id=tid("t1"),
      role=RD,
      member_id="member-rd-2",
      at_ms=3000L,
      expected_revision=2L,
    ),
  )
  assert_eq(replaced.next_state.task(tid("t1")).unwrap().assignments, [
    { role: RD, member_id: "member-rd-2", },
  ])
  assert_true(
    rejection_of(
      replaced.next_state,
      AssignRole(
        id=tid("t1"),
        role=SET,
        member_id=" ",
        at_ms=4000L,
        expected_revision=3L,
      ),
    )
    is InvalidInput(_),
  )
}
