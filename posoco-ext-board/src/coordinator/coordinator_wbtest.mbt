///|
fn cid(s : String) -> @domain.BoardTaskId {
  @domain.BoardTaskId::BoardTaskId(s)
}

///|
fn caid(s : String) -> @domain.AttemptId {
  @domain.AttemptId::AttemptId(s)
}

///|
fn c_create(id : String, rev : Int64) -> @domain.BoardCommand {
  @domain.BoardCommand::CreateTask(
    id=cid(id),
    title="task \{id}",
    description="",
    priority=@domain.Normal,
    definition_of_done=["draft"],
    dependencies=[],
    at_ms=1000L,
    expected_revision=rev,
  )
}

///|
fn c_move(id : String, rev : Int64) -> @domain.BoardCommand {
  @domain.BoardCommand::MoveTask(
    id=cid(id),
    to=@domain.Refining,
    at_ms=2000L,
    expected_revision=rev,
  )
}

///|
fn[T] assert_rejected(
  result : Result[T, BoardCoordinatorError],
  expected : BoardCoordinatorError,
) -> Unit raise {
  match result {
    Ok(_) => fail("expected the request to be rejected")
    Err(error) => assert_eq(error, expected)
  }
}

///|
/// Attach, then await the startup restore. Tests below work against a Ready
/// coordinator over the default private memory store.
async fn ready_coordinator(group : @async.TaskGroup[Unit]) -> BoardCoordinator {
  let coordinator = BoardCoordinator::BoardCoordinator()
  coordinator.attach(group~)
  assert_true(coordinator.wait_ready() is Ok(_))
  coordinator
}

///|
async test "coordinator requests fail clearly before attach" {
  let coordinator = BoardCoordinator::BoardCoordinator()
  assert_eq(coordinator.status(), Detached)
  assert_rejected(coordinator.submit(command=c_create("t1", 0L)), NotAttached)
  assert_rejected(coordinator.wait_ready(), NotAttached)
  assert_rejected(coordinator.revision(), NotAttached)
  assert_rejected(coordinator.snapshot(), NotAttached)
  assert_rejected(coordinator.tasks(), NotAttached)
  assert_rejected(coordinator.attempts(), NotAttached)
  assert_rejected(coordinator.task(id=cid("t1")), NotAttached)
  assert_rejected(coordinator.attempt(id=caid("a1")), NotAttached)
}

///|
async test "the loop settles queued mutations in fifo order through their completion queues" {
  @async.with_task_group(group => {
    let coordinator = ready_coordinator(group)
    let actor = coordinator.actor.unwrap()
    // Raw mailbox tells, no ask barrier anywhere: only on_cmd plus its
    // persist reports can fill these per-submission queues.
    let first : SubmissionCompletion = @aqueue.Queue(kind=@aqueue.Blocking(1))
    let second : SubmissionCompletion = @aqueue.Queue(kind=@aqueue.Blocking(1))
    assert_true(actor.tell(Submit(c_create("t1", 0L), first)) is Ok(_))
    assert_true(actor.tell(Submit(c_move("t1", 1L), second)) is Ok(_))
    assert_eq(first.get(), Ok([@domain.TaskCreated(id=cid("t1"), at_ms=1000L)]))
    assert_eq(
      second.get(),
      Ok([
        @domain.TaskStageChanged(
          id=cid("t1"),
          from=@domain.Created,
          to=@domain.Refining,
          at_ms=2000L,
        ),
      ]),
    )
    assert_eq(coordinator.revision(), Ok(2L))
    coordinator.shutdown()
  })
}

///|
async test "mutations commit in fifo order and typed rejections keep state" {
  @async.with_task_group(group => {
    let coordinator = ready_coordinator(group)
    let events = coordinator.submit(command=c_create("t1", 0L)).unwrap()
    assert_eq(events, [@domain.TaskCreated(id=cid("t1"), at_ms=1000L)])
    assert_eq(coordinator.revision(), Ok(1L))
    // Duplicate id is a typed domain rejection; revision is untouched.
    assert_rejected(
      coordinator.submit(command=c_create("t1", 1L)),
      Rejected(@domain.DuplicateTask(task=cid("t1"))),
    )
    assert_eq(coordinator.revision(), Ok(1L))
    // Stale revision expectations name expected and actual.
    assert_rejected(
      coordinator.submit(command=c_move("t1", 5L)),
      Rejected(@domain.RevisionConflict(expected=5L, actual=1L)),
    )
    assert_rejected(
      coordinator.submit(command=c_create("t1", 0L)),
      Rejected(@domain.RevisionConflict(expected=0L, actual=1L)),
    )
    // FIFO continues after rejections.
    let moved = coordinator.submit(command=c_move("t1", 1L)).unwrap()
    assert_eq(moved.length(), 1)
    assert_eq(coordinator.revision(), Ok(2L))
    let task = coordinator.task(id=cid("t1")).unwrap().unwrap()
    assert_eq(task.stage, @domain.Refining)
    coordinator.shutdown()
  })
}

///|
async test "two concurrent callers of one revision produce exactly one success" {
  @async.with_task_group(group => {
    let coordinator = ready_coordinator(group)
    let results = @async.all([
      () => coordinator.submit(command=c_create("t1", 0L)),
      () => coordinator.submit(command=c_create("t1", 0L)),
    ])
    assert_eq(results.length(), 2)
    let winners = results.filter(result => result is Ok(_))
    let losers = results.filter(result => result is Err(Rejected(_)))
    assert_eq(winners.length(), 1)
    assert_eq(losers.length(), 1)
    assert_rejected(
      losers[0],
      Rejected(@domain.RevisionConflict(expected=0L, actual=1L)),
    )
    assert_eq(coordinator.revision(), Ok(1L))
    assert_eq(coordinator.tasks().unwrap().length(), 1)
    coordinator.shutdown()
  })
}

///|
async test "attach is idempotent and keeps one committed state" {
  @async.with_task_group(group => {
    let coordinator = ready_coordinator(group)
    let _ = coordinator.submit(command=c_create("t1", 0L))
    coordinator.attach(group~)
    coordinator.attach(group~)
    // The same loop still serves: revision 1 is still the live expectation.
    let _ = coordinator.submit(command=c_move("t1", 1L))
    assert_eq(coordinator.revision(), Ok(2L))
    assert_eq(coordinator.tasks().unwrap().length(), 1)
    coordinator.shutdown()
  })
}

///|
async test "queries return detached copies" {
  @async.with_task_group(group => {
    let coordinator = ready_coordinator(group)
    let _ = coordinator.submit(command=c_create("t1", 0L))
    let first = coordinator.snapshot().unwrap()
    let second = coordinator.snapshot().unwrap()
    assert_eq(first, second)
    assert_eq(first.revision, 1L)
    // Mutating a returned snapshot must not smear the committed state.
    first.tasks[0].definition_of_done.push("late")
    first.tasks[0].dependencies.push(cid("ghost"))
    let third = coordinator.snapshot().unwrap()
    assert_eq(third, second)
    assert_eq(third.tasks[0].definition_of_done, ["draft"])
    let task = coordinator.task(id=cid("t1")).unwrap().unwrap()
    task.definition_of_done.push("late")
    assert_eq(
      coordinator.task(id=cid("t1")).unwrap().unwrap().definition_of_done,
      ["draft"],
    )
    assert_eq(coordinator.tasks().unwrap().length(), 1)
    assert_eq(coordinator.attempts().unwrap().length(), 0)
    assert_eq(coordinator.task(id=cid("ghost")).unwrap(), None)
    assert_eq(coordinator.attempt(id=caid("a1")).unwrap(), None)
    assert_eq(coordinator.revision(), Ok(1L))
    coordinator.shutdown()
  })
}

///|
async test "shutdown closes admission and reattach restores the durable board" {
  @async.with_task_group(group => {
    let coordinator = BoardCoordinator::BoardCoordinator()
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    let _ = coordinator.submit(command=c_create("t1", 0L))
    coordinator.shutdown()
    assert_eq(coordinator.status(), Stopped)
    assert_rejected(coordinator.revision(), Closed)
    assert_rejected(coordinator.submit(command=c_move("t1", 1L)), Closed)
    assert_rejected(coordinator.snapshot(), Closed)
    // Idempotent shutdown.
    coordinator.shutdown()
    // Re-attach restores the same durable board: the revision and the task
    // survive the shutdown cycle.
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    assert_eq(coordinator.revision(), Ok(1L))
    assert_eq(coordinator.tasks().unwrap().length(), 1)
    let _ = coordinator.submit(command=c_move("t1", 1L))
    assert_eq(coordinator.revision(), Ok(2L))
    coordinator.shutdown()
    // A fresh coordinator owns a fresh memory store and starts empty.
    let fresh = BoardCoordinator::BoardCoordinator()
    fresh.attach(group~)
    assert_true(fresh.wait_ready() is Ok(_))
    assert_eq(fresh.revision(), Ok(0L))
    fresh.shutdown()
  })
}

///|
fn c_create_dod(
  id : String,
  rev : Int64,
  dod : Array[String],
) -> @domain.BoardCommand {
  @domain.BoardCommand::CreateTask(
    id=cid(id),
    title="task \{id}",
    description="",
    priority=@domain.Normal,
    definition_of_done=dod,
    dependencies=[],
    at_ms=1000L,
    expected_revision=rev,
  )
}

///|
async test "caller mutation while queued cannot alter the admitted command" {
  @async.with_task_group(group => {
    let coordinator = ready_coordinator(group)
    let dod : Array[String] = ["draft"]
    // The submit task deep-copies the command before its first suspension,
    // so the mutation task's push can never reach the admitted input.
    let results = @async.all([
      () => {
        let submitted = coordinator.submit(command=c_create_dod("t1", 0L, dod))
        if submitted is Ok(_) {
          1
        } else {
          0
        }
      },
      () => {
        dod.push("late")
        2
      },
    ])
    assert_eq(results, [1, 2])
    let task = coordinator.task(id=cid("t1")).unwrap().unwrap()
    assert_eq(task.definition_of_done, ["draft"])
    // Mutation after a completed submit is equally powerless.
    dod.push("later")
    assert_eq(
      coordinator.task(id=cid("t1")).unwrap().unwrap().definition_of_done,
      ["draft"],
    )
    coordinator.shutdown()
  })
}

///|
async test "shutdown cleanup completes even when the caller is cancelled" {
  @async.with_task_group(group => {
    let coordinator = ready_coordinator(group)
    let _ = coordinator.submit(command=c_create("t1", 0L))
    let task = group.spawn(() => coordinator.shutdown())
    // Let the teardown enter its join, then cancel the caller: the
    // protected cleanup must still close admission and join the loop.
    @async.sleep(10)
    task.cancel()
    let _ = task.wait() catch { _ => () }
    assert_eq(coordinator.status(), Stopped)
    assert_rejected(coordinator.revision(), Closed)
    assert_rejected(coordinator.submit(command=c_create("t1", 0L)), Closed)
  })
}

///|
async test "stream_snapshot answers the live configured cursor per query" {
  @async.with_task_group(group => {
    let cursor : Ref[Int64] = Ref(0L)
    let coordinator = BoardCoordinator::BoardCoordinator(stream_cursor=() => {
      cursor.val
    })
    coordinator.attach(group~)
    // Loading answers explicitly instead of a fabricated stream position.
    assert_rejected(coordinator.stream_snapshot(), Initializing)
    assert_true(coordinator.wait_ready() is Ok(_))
    // The boundary is the actual cursor at query time, not a commit count.
    cursor.val = 20L
    let boundary = coordinator.stream_snapshot().unwrap()
    assert_eq(boundary.stream_seq, 20L)
    assert_eq(boundary.board_snapshot.revision, 0L)
    // Cursor movement alone moves the answered boundary.
    cursor.val = 21L
    assert_eq(coordinator.stream_cursor(), 21L)
    assert_eq(coordinator.stream_snapshot().unwrap().stream_seq, 21L)
    // A commit keeps the same answering rule: board revision plus the
    // cursor observed while the loop owned the committed state.
    assert_true(coordinator.submit(command=c_create("t1", 0L)) is Ok(_))
    cursor.val = 22L
    let after = coordinator.stream_snapshot().unwrap()
    assert_eq(after.board_snapshot.revision, 1L)
    assert_eq(after.stream_seq, 22L)
    coordinator.shutdown()
  })
}

///|
async test "on_commit observes every commit synchronously with detached inputs" {
  @async.with_task_group(group => {
    let observed : Array[Array[@domain.BoardEvent]] = []
    let revisions : Array[Int64] = []
    let coordinator = BoardCoordinator::BoardCoordinator(on_commit=(
      snapshot,
      events,
    ) => {
      revisions.push(snapshot.revision)
      observed.push(events)
    })
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    // An unchanged startup load is not a commit: the hook never observes it.
    assert_eq(observed.length(), 0)
    let returned = coordinator.submit(command=c_create("t1", 0L)).unwrap()
    // The hook ran before the committing caller was answered.
    assert_eq(observed.length(), 1)
    assert_eq(revisions, [1L])
    assert_eq(observed[0], returned)
    // Deeply detached: mutating the caller's copy cannot reach the hook's
    // delivered events.
    returned.push(@domain.TaskCreated(id=cid("mutated"), at_ms=9L))
    assert_eq(observed[0].length(), 1)
    // Rejections are not commits.
    assert_rejected(
      coordinator.submit(command=c_create("t1", 1L)),
      Rejected(@domain.DuplicateTask(task=cid("t1"))),
    )
    assert_eq(observed.length(), 1)
    coordinator.shutdown()
  })
}

///|
async test "startup recovery streams its recovery events exactly once" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let initial = snapshot_of(9L, [task_record("task", @domain.Running, 10L)], [])
    store.loads.push_back(LoadOk(load_of(initial)))
    let observed : Array[Int64] = []
    let coordinator = BoardCoordinator::BoardCoordinator(
      store~,
      now_ms=() => 5L,
      on_commit=(snapshot, _events) => observed.push(snapshot.revision),
    )
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    // The recovery replacement is one durable commit: observed once, with
    // the recovered revision.
    assert_eq(observed, [10L])
    assert_eq(coordinator.revision(), Ok(10L))
    coordinator.shutdown()
    // An unchanged restart streams nothing.
    let replayed : Array[Int64] = []
    let again = BoardCoordinator::BoardCoordinator(store~, now_ms=() => 5L, on_commit=(
      snapshot,
      _events,
    ) => replayed.push(snapshot.revision))
    again.attach(group~)
    assert_true(again.wait_ready() is Ok(_))
    assert_eq(replayed, [])
    assert_eq(again.revision(), Ok(10L))
    again.shutdown()
  })
}
