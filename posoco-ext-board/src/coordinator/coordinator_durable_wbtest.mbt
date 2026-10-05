///|
/// Deterministic durable-coordinator tests over a fully controllable
/// store. Gates are async queues: a parked worker is released exactly when
/// the test decides, so no timing assertions are needed.

///|
/// A single-entry gate. The store signals `entered` and then parks until
/// the test puts a token into `release`.
priv struct ScriptGate {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
fn new_gate() -> ScriptGate {
  {
    entered: @aqueue.Queue(kind=@aqueue.Blocking(1)),
    release: @aqueue.Queue(kind=@aqueue.Blocking(1)),
  }
}

///|
priv enum PersistStep {
  StepOk
  StepFail(@store.StoreFailureStage)
  StepUncertain(String)
  StepGate(ScriptGate)
  StepGatedFailure(ScriptGate, @store.BoardStoreError)
}

///|
priv enum LoadStep {
  LoadOk(@store.BoardLoad)
  LoadFail(@store.BoardStoreError)
  LoadGate(ScriptGate, @store.BoardLoad)
}

///|
priv struct PersistedWrite {
  revision : Int64
  events : Array[@domain.BoardEvent]
}

///|
priv struct ScriptedBoardStore {
  loads : @deque.Deque[LoadStep]
  persists : @deque.Deque[PersistStep]
  /// The store's committed board: every successful persist replaces it and
  /// every load without a scripted override returns it.
  mut durable : @domain.BoardStateSnapshot
  journal : Array[@store.JournalRecord]
  mut persist_attempts : Int
  committed_writes : Array[PersistedWrite]
}

///|
fn ScriptedBoardStore::new() -> ScriptedBoardStore {
  {
    loads: @deque.Deque([]),
    persists: @deque.Deque([]),
    durable: @store.empty_snapshot(),
    journal: [],
    persist_attempts: 0,
    committed_writes: [],
  }
}

///|
/// A persist crossed its visibility boundary: the board is replaced and
/// the transaction recorded.
fn ScriptedBoardStore::settle(
  self : ScriptedBoardStore,
  snapshot : @domain.BoardStateSnapshot,
  events : Array[@domain.BoardEvent],
) -> Unit {
  self.durable = snapshot.copy_detached()
  self.committed_writes.push({ revision: snapshot.revision, events, })
  for event in events {
    self.journal.push({ schema_version: 1, revision: snapshot.revision, event, })
  }
}

///|
/// Assert a typed restore failure without pinning the store's message text.
fn[T] assert_typed_restore_failure(
  result : Result[T, BoardCoordinatorError],
) -> Unit raise {
  match result {
    Err(RestoreFailed(Store(@store.InvalidData(_)))) => ()
    Err(_) => fail("expected a typed store restore failure")
    Ok(_) => fail("expected the restore to fail")
  }
}

///|
impl @store.BoardStore for ScriptedBoardStore with fn load(self) {
  match self.loads.pop_front() {
    None =>
      Ok({
        snapshot: self.durable.copy_detached(),
        journal: self.journal.copy(),
      })
    Some(LoadOk(load)) => Ok(load)
    Some(LoadFail(error)) => Err(error)
    Some(LoadGate(gate, load)) => {
      let _ = gate.entered.try_put(())
      let _ = gate.release.get()
      Ok(load)
    }
  }
}

///|
impl @store.BoardStore for ScriptedBoardStore with fn persist(
  self,
  snapshot,
  events,
) {
  self.persist_attempts = self.persist_attempts + 1
  match self.persists.pop_front() {
    None => {
      self.settle(snapshot, events)
      Ok(())
    }
    Some(StepOk) => {
      self.settle(snapshot, events)
      Ok(())
    }
    Some(StepFail(stage)) => Err(@store.Injected(stage))
    Some(StepUncertain(detail)) => Err(@store.DurabilityUncertain(detail))
    Some(StepGate(gate)) => {
      let _ = gate.entered.try_put(())
      let _ = gate.release.get()
      self.settle(snapshot, events)
      Ok(())
    }
    Some(StepGatedFailure(gate, error)) => {
      gate.entered.put(())
      gate.release.get()
      Err(error)
    }
  }
}

///|
fn scripted_coordinator(
  store : ScriptedBoardStore,
  now_ms? : () -> Int64 = () => 0L,
) -> BoardCoordinator {
  BoardCoordinator(store~, now_ms~)
}

///|
fn task_record(
  id : String,
  stage : @domain.BoardStage,
  updated_at_ms : Int64,
  ready_since_ms? : Int64? = None,
  created_at_ms? : Int64 = 1L,
  definition_of_done? : Array[String] = [],
) -> @domain.BoardTask {
  @domain.BoardTask::from_record(
    id=cid(id),
    title="task \{id}",
    description="",
    stage~,
    priority=@domain.Normal,
    definition_of_done~,
    dependencies=[],
    created_at_ms~,
    updated_at_ms~,
    ready_since_ms~,
  )
}

///|
fn attempt_record(
  id : String,
  task : String,
  status : @domain.AttemptStatus,
  finished_at_ms? : Int64? = None,
) -> @domain.Attempt {
  @domain.Attempt::from_record(
    id=caid(id),
    task_id=cid(task),
    kind=@domain.Execute,
    status~,
    review=None,
    created_at_ms=1L,
    started_at_ms=Some(2L),
    finished_at_ms~,
    updated_at_ms=2L,
  )
}

///|
fn snapshot_of(
  revision : Int64,
  tasks : Array[@domain.BoardTask],
  attempts : Array[@domain.Attempt],
) -> @domain.BoardStateSnapshot {
  { revision, tasks, attempts, }
}

///|
fn load_of(snapshot : @domain.BoardStateSnapshot) -> @store.BoardLoad {
  { snapshot, journal: [], }
}

///|
/// Release one startup load immediately so the coordinator becomes Ready.
async fn ready_scripted(
  group : @async.TaskGroup[Unit],
  store : ScriptedBoardStore,
) -> BoardCoordinator {
  let coordinator = scripted_coordinator(store)
  coordinator.attach(group~)
  assert_true(coordinator.wait_ready() is Ok(_))
  coordinator
}

///|
async test "startup restores an empty board and reports loading then ready" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    assert_eq(coordinator.status(), Loading)
    assert_true(coordinator.wait_ready() is Ok(_))
    assert_eq(coordinator.status(), Ready)
    assert_eq(coordinator.revision(), Ok(0L))
    assert_eq(coordinator.snapshot().unwrap().tasks.length(), 0)
    let events = coordinator.submit(command=c_create("t1", 0L)).unwrap()
    assert_eq(events, [@domain.TaskCreated(id=cid("t1"), at_ms=1000L)])
    assert_eq(coordinator.revision(), Ok(1L))
    // The submission was durable before it was ever acknowledged.
    assert_eq(store.persist_attempts, 1)
    assert_eq(store.committed_writes.length(), 1)
    assert_eq(store.committed_writes[0].revision, 1L)
    coordinator.shutdown()
  })
}

///|
async test "startup restores a nonzero durable board" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let seeded = snapshot_of(
      2L,
      [
        task_record("t1", @domain.Created, 10L),
        task_record("t2", @domain.Refining, 20L),
      ],
      [],
    )
    store.loads.push_back(LoadOk(load_of(seeded)))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    assert_eq(coordinator.revision(), Ok(2L))
    assert_eq(coordinator.tasks().unwrap().length(), 2)
    assert_eq(
      coordinator.task(id=cid("t2")).unwrap().unwrap().stage,
      @domain.Refining,
    )
    // The restore did not write anything: a valid board needs no recovery.
    assert_eq(store.persist_attempts, 0)
    // New submissions continue from the restored revision exactly.
    let _ = coordinator.submit(command=c_create("t3", 2L))
    assert_eq(coordinator.revision(), Ok(3L))
    coordinator.shutdown()
  })
}

///|
async test "startup recovers running work, persists it once and stays idempotent" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let running = snapshot_of(5L, [task_record("t1", @domain.Running, 20L)], [
      attempt_record("a1", "t1", @domain.Running),
    ])
    store.loads.push_back(LoadOk(load_of(running)))
    let coordinator = scripted_coordinator(store, now_ms=() => 77L)
    coordinator.attach(group~)
    assert_true(coordinator.wait_ready() is Ok(_))
    // The recovery persisted exactly one transaction with both events.
    assert_eq(store.persist_attempts, 1)
    assert_eq(store.committed_writes.length(), 1)
    assert_eq(store.committed_writes[0].revision, 6L)
    assert_eq(store.committed_writes[0].events, [
      @domain.TaskStageChanged(
        id=cid("t1"),
        from=@domain.Running,
        to=@domain.Suspended,
        at_ms=77L,
      ),
      @domain.AttemptFinished(
        id=caid("a1"),
        task_id=cid("t1"),
        outcome=@domain.Interrupted,
        at_ms=77L,
      ),
    ])
    // The restored board reflects the recovery, not the raw snapshot.
    assert_eq(coordinator.revision(), Ok(6L))
    let task = coordinator.task(id=cid("t1")).unwrap().unwrap()
    assert_eq(task.stage, @domain.Suspended)
    assert_eq(task.updated_at_ms, 77L)
    let attempt = coordinator.attempt(id=caid("a1")).unwrap().unwrap()
    assert_eq(attempt.status, @domain.Interrupted)
    assert_eq(attempt.finished_at_ms, Some(77L))
    // The durable store carries the recovery forward.
    let reloaded = @store.BoardStore::load(store).unwrap()
    assert_eq(reloaded.snapshot.revision, 6L)
    coordinator.shutdown()
    // A second restart after a successful recovery changes nothing.
    let again = scripted_coordinator(store, now_ms=() => 500L)
    again.attach(group~)
    assert_true(again.wait_ready() is Ok(_))
    assert_eq(again.revision(), Ok(6L))
    assert_eq(store.persist_attempts, 1)
    assert_eq(again.task(id=cid("t1")).unwrap().unwrap().updated_at_ms, 77L)
    again.shutdown()
  })
}

///|
async test "a corrupt snapshot fails restore with a typed error and rejects parked submissions" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    // Store-decodable, but the attempt references a task that does not
    // exist: from_snapshot must reject it.
    let corrupt = snapshot_of(3L, [], [
      attempt_record("a1", "ghost", @domain.Queued),
    ])
    store.loads.push_back(LoadOk(load_of(corrupt)))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    // The snapshot is store-decodable in structure but fails validation:
    // the recovery layer reports it as a typed store error before the
    // coordinator ever serves state. from_snapshot rejects it directly too.
    match @domain.BoardState::from_snapshot(corrupt) {
      Err(@domain.TaskMissing(task~)) => assert_eq(task, cid("ghost"))
      Err(_) => fail("expected the domain TaskMissing rejection")
      Ok(_) => fail("expected the corrupt snapshot to be rejected")
    }
    // Parked behind the failed restore, then rejected explicitly.
    let parked = group.spawn(() => {
      coordinator.submit(command=c_create("t1", 0L))
    })
    assert_typed_restore_failure(coordinator.wait_ready())
    assert_eq(coordinator.status(), Failed)
    assert_typed_restore_failure(parked.wait())
    // Read-only: every later request answers with the typed failure.
    assert_true(
      coordinator.submit(command=c_create("t1", 0L))
      is Err(RestoreFailed(Store(_))),
    )
    assert_true(coordinator.revision() is Err(RestoreFailed(Store(_))))
    assert_eq(store.persist_attempts, 0)
    coordinator.shutdown()
    assert_eq(coordinator.status(), Stopped)
  })
}

///|
async test "a recovery persist failure fails restore before anything is served" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let running = snapshot_of(1L, [task_record("t1", @domain.Running, 5L)], [])
    store.loads.push_back(LoadOk(load_of(running)))
    store.persists.push_back(StepFail(@store.TempWrite))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    let parked = group.spawn(() => {
      coordinator.submit(command=c_create("t1", 0L))
    })
    assert_eq(
      coordinator.wait_ready(),
      Err(RestoreFailed(Store(@store.Injected(@store.TempWrite)))),
    )
    assert_eq(coordinator.status(), Failed)
    assert_eq(
      parked.wait(),
      Err(RestoreFailed(Store(@store.Injected(@store.TempWrite)))),
    )
    // The failed recovery persist never reached the store's committed set.
    assert_eq(store.persist_attempts, 1)
    assert_eq(store.committed_writes.length(), 0)
    coordinator.shutdown()
  })
}

///|
async test "startup recovery uncertainty that reloads recovered candidate becomes ready" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let running = snapshot_of(4L, [task_record("t1", @domain.Running, 5L)], [
      attempt_record("a1", "t1", @domain.Running),
    ])
    let recovered = @store.recover_snapshot(running, at_ms=77L).unwrap()
    store.loads.push_back(LoadOk(load_of(running)))
    store.persists.push_back(StepUncertain("directory fsync lost"))
    store.loads.push_back(LoadOk(load_of(recovered.snapshot)))
    let coordinator = scripted_coordinator(store, now_ms=() => 77L)
    coordinator.attach(group~)

    assert_true(coordinator.wait_ready() is Ok(_))
    assert_eq(coordinator.status(), Ready)
    assert_eq(coordinator.revision(), Ok(5L))
    assert_eq(
      coordinator.task(id=cid("t1")).unwrap().unwrap().stage,
      @domain.Suspended,
    )
    assert_eq(
      coordinator.attempt(id=caid("a1")).unwrap().unwrap().status,
      @domain.Interrupted,
    )
    assert_eq(store.persist_attempts, 1)
    coordinator.shutdown()
  })
}

///|
async test "startup recovery uncertainty never exposes unrecovered old snapshot" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let running = snapshot_of(4L, [task_record("t1", @domain.Running, 5L)], [
      attempt_record("a1", "t1", @domain.Running),
    ])
    store.loads.push_back(LoadOk(load_of(running)))
    store.persists.push_back(StepUncertain("directory fsync lost"))
    store.loads.push_back(LoadOk(load_of(running)))
    let coordinator = scripted_coordinator(store, now_ms=() => 77L)
    coordinator.attach(group~)

    match coordinator.wait_ready() {
      Err(RestoreFailed(Store(@store.DurabilityUncertain(_)))) => ()
      _ =>
        fail(
          "old Running snapshot after uncertain recovery must not become Ready",
        )
    }
    assert_eq(coordinator.status(), Failed)
    assert_true(
      coordinator.revision()
      is Err(RestoreFailed(Store(@store.DurabilityUncertain(_)))),
    )
    assert_eq(store.persist_attempts, 1)
    coordinator.shutdown()
  })
}

///|
async test "every pre-visibility persist failure keeps the committed board untouched" {
  for
    stage in [
      @store.TempWrite,
      @store.TempFsync,
      @store.JournalAppend,
      @store.JournalFsync,
      @store.Rename,
    ] {
    @async.with_task_group(group => {
      let store = ScriptedBoardStore::new()
      let coordinator = ready_scripted(group, store)
      // A first successful transaction establishes a committed baseline.
      store.persists.push_back(StepOk)
      assert_eq(
        coordinator.submit(command=c_create("t1", 0L)).unwrap().length(),
        1,
      )
      assert_eq(coordinator.revision(), Ok(1L))
      // The failing write is rejected with the typed store error.
      store.persists.push_back(StepFail(stage))
      assert_rejected(
        coordinator.submit(command=c_move("t1", 1L)),
        PersistFailed(@store.Injected(stage)),
      )
      assert_eq(coordinator.revision(), Ok(1L))
      assert_eq(
        coordinator.task(id=cid("t1")).unwrap().unwrap().stage,
        @domain.Created,
      )
      assert_eq(store.persist_attempts, 2)
      assert_eq(store.committed_writes.length(), 1)
      // The coordinator stays ready and a retried write commits.
      assert_eq(
        coordinator.submit(command=c_move("t1", 1L)).unwrap().length(),
        1,
      )
      assert_eq(coordinator.revision(), Ok(2L))
      assert_eq(store.committed_writes.length(), 2)
      coordinator.shutdown()
    })
  }
}

///|
async test "uncertain durability that finds the candidate keeps the commit" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    let landed = snapshot_of(
      1L,
      [
        task_record("t1", @domain.Created, 1000L, created_at_ms=1000L, definition_of_done=[
          "draft",
        ]),
      ],
      [],
    )
    store.persists.push_back(StepUncertain("directory fsync lost"))
    store.loads.push_back(LoadOk(load_of(landed)))
    // The caller learns the outcome was uncertain, not success.
    assert_eq(
      coordinator.submit(command=c_create("t1", 0L)),
      Err(DurabilityUncertain("directory fsync lost")),
    )
    // The reconciliation committed the candidate that had landed.
    assert_eq(coordinator.status(), Ready)
    assert_eq(coordinator.revision(), Ok(1L))
    assert_eq(
      coordinator.task(id=cid("t1")).unwrap().unwrap().created_at_ms,
      1000L,
    )
    assert_eq(store.persist_attempts, 1)
    // A refreshed caller continues from the committed revision.
    let _ = coordinator.submit(command=c_move("t1", 1L))
    assert_eq(coordinator.revision(), Ok(2L))
    coordinator.shutdown()
  })
}

///|
async test "uncertain durability that finds the old board retains it" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    store.persists.push_back(StepUncertain("directory fsync lost"))
    store.loads.push_back(LoadOk(load_of(@store.empty_snapshot())))
    assert_eq(
      coordinator.submit(command=c_create("t1", 0L)),
      Err(DurabilityUncertain("directory fsync lost")),
    )
    // The prior board was retained; the candidate never became visible.
    assert_eq(coordinator.status(), Ready)
    assert_eq(coordinator.revision(), Ok(0L))
    assert_eq(coordinator.task(id=cid("t1")).unwrap(), None)
    // The original revision expectation is still honest and wins now.
    assert_eq(
      coordinator.submit(command=c_create("t1", 0L)).unwrap().length(),
      1,
    )
    assert_eq(coordinator.revision(), Ok(1L))
    coordinator.shutdown()
  })
}

///|
async test "uncertainty against a foreign authoritative board fails read-only and rejects deferred" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    let foreign = snapshot_of(7L, [task_record("zz", @domain.Done, 9L)], [])
    let gate = new_gate()
    store.persists.push_back(StepUncertain("directory fsync lost"))
    store.loads.push_back(LoadGate(gate, load_of(foreign)))
    let first = group.spawn(() => coordinator.submit(command=c_create("t1", 0L)))
    // Parked mid-reconciliation; further submissions queue behind it.
    let second = group.spawn(() => {
      coordinator.submit(command=c_create("t2", 1L))
    })
    let _ = gate.entered.get()
    assert_eq(coordinator.status(), Reconciling)
    assert_rejected(coordinator.revision(), Initializing)
    assert_eq(store.persist_attempts, 1)
    assert_eq(store.committed_writes.length(), 0)
    // The authoritative board matches neither the candidate nor the prior
    // state: no committed board can be proven, so everything parked behind
    // the transaction is rejected and the coordinator turns read-only.
    let _ = gate.release.try_put(())
    let cause : BoardRestoreError = Store(
      @store.DurabilityUncertain(
        "reloaded board matches neither the attempted write nor the prior state",
      ),
    )
    assert_eq(first.wait(), Err(RestoreFailed(cause)))
    assert_eq(second.wait(), Err(RestoreFailed(cause)))
    assert_eq(coordinator.status(), Failed)
    // The last restored board stays readable read-only; nothing new can be
    // proposed and wait_ready reports the durable failure.
    assert_eq(coordinator.revision(), Ok(0L))
    assert_eq(coordinator.snapshot().unwrap().tasks.length(), 0)
    assert_rejected(
      coordinator.submit(command=c_create("t1", 0L)),
      RestoreFailed(cause),
    )
    assert_rejected(coordinator.wait_ready(), RestoreFailed(cause))
    assert_eq(store.committed_writes.length(), 0)
    coordinator.shutdown()
    assert_eq(coordinator.status(), Stopped)
  })
}

///|
async test "a failed reload after uncertainty turns the coordinator read-only" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    store.persists.push_back(StepUncertain("directory fsync lost"))
    store.loads.push_back(LoadFail(@store.Io("reload disk gone")))
    assert_eq(
      coordinator.submit(command=c_create("t1", 0L)),
      Err(RestoreFailed(Store(@store.Io("reload disk gone")))),
    )
    assert_eq(coordinator.status(), Failed)
    assert_rejected(
      coordinator.wait_ready(),
      RestoreFailed(Store(@store.Io("reload disk gone"))),
    )
    assert_rejected(
      coordinator.submit(command=c_create("t1", 0L)),
      RestoreFailed(Store(@store.Io("reload disk gone"))),
    )
    // The last restored board stays readable read-only.
    assert_eq(coordinator.revision(), Ok(0L))
    assert_eq(coordinator.snapshot().unwrap().tasks.length(), 0)
    assert_eq(store.committed_writes.length(), 0)
    coordinator.shutdown()
  })
}

///|
async test "same revision concurrency: one durable winner, one typed conflict" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    let results = @async.all([
      () => coordinator.submit(command=c_create("t1", 0L)),
      () => coordinator.submit(command=c_create("t1", 0L)),
    ])
    assert_eq(results.filter(result => result is Ok(_)).length(), 1)
    assert_eq(results.filter(result => result is Err(Rejected(_))).length(), 1)
    assert_rejected(
      results.filter(result => result is Err(Rejected(_)))[0],
      Rejected(@domain.RevisionConflict(expected=0L, actual=1L)),
    )
    assert_eq(coordinator.revision(), Ok(1L))
    // Exactly one durable transaction backs the one winner.
    assert_eq(store.persist_attempts, 1)
    assert_eq(store.committed_writes.length(), 1)
    coordinator.shutdown()
  })
}

///|
async test "same revision concurrency: a failed first write rolls back and the parked proposal wins" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    store.persists.push_back(StepFail(@store.TempWrite))
    store.persists.push_back(StepOk)
    let results = @async.all([
      () => coordinator.submit(command=c_create("t1", 0L)),
      () => coordinator.submit(command=c_create("t1", 0L)),
    ])
    assert_eq(results.filter(result => result is Ok(_)).length(), 1)
    let failures = results.filter(result => result is Err(PersistFailed(_)))
    assert_eq(failures.length(), 1)
    assert_eq(
      failures[0],
      Err(PersistFailed(@store.Injected(@store.TempWrite))),
    )
    // The parked proposal was freshly proposed against the rolled-back
    // board and became the only durable transaction.
    assert_eq(coordinator.revision(), Ok(1L))
    assert_eq(coordinator.tasks().unwrap().length(), 1)
    assert_eq(store.persist_attempts, 2)
    assert_eq(store.committed_writes.length(), 1)
    assert_eq(store.committed_writes[0].revision, 1L)
    coordinator.shutdown()
  })
}

///|
async test "deferred submissions persist in fifo order, one transaction each, never early" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let gate = new_gate()
    let coordinator = ready_scripted(group, store)
    store.persists.push_back(StepGate(gate))
    store.persists.push_back(StepOk)
    store.persists.push_back(StepOk)
    let a = group.spawn(() => coordinator.submit(command=c_create("t1", 0L)))
    // A holds the single in-flight persist slot.
    let _ = gate.entered.get()
    assert_eq(store.persist_attempts, 1)
    // B and C queue behind it and must not touch the store early.
    let b = group.spawn(() => coordinator.submit(command=c_create("t2", 1L)))
    let c = group.spawn(() => coordinator.submit(command=c_create("t3", 2L)))
    @async.sleep(1)
    assert_eq(store.persist_attempts, 1)
    assert_eq(store.committed_writes.length(), 0)
    // Releasing A settles it, then B, then C — one transaction each.
    let _ = gate.release.try_put(())
    assert_eq(a.wait().unwrap().length(), 1)
    assert_eq(b.wait().unwrap().length(), 1)
    assert_eq(c.wait().unwrap().length(), 1)
    assert_eq(store.persist_attempts, 3)
    assert_eq(store.committed_writes.map(write => write.revision), [1L, 2L, 3L])
    assert_eq(
      store.committed_writes.map(write => {
        match write.events[0] {
          @domain.TaskCreated(id~, ..) => id.value
          _ => "other"
        }
      }),
      ["t1", "t2", "t3"],
    )
    assert_eq(coordinator.revision(), Ok(3L))
    coordinator.shutdown()
  })
}

///|
async test "queries never see the pending candidate and an unfinished submit leaks nothing" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let gate = new_gate()
    let coordinator = ready_scripted(group, store)
    store.persists.push_back(StepGate(gate))
    let submitted = group.spawn(() => {
      coordinator.submit(command=c_create("t1", 0L))
    })
    // The persist is in flight: the caller has no result yet and the
    // committed board is still the old one.
    let _ = gate.entered.get()
    assert_eq(coordinator.revision(), Ok(0L))
    assert_eq(coordinator.snapshot().unwrap().tasks.length(), 0)
    assert_eq(coordinator.task(id=cid("t1")).unwrap(), None)
    assert_eq(coordinator.attempts().unwrap().length(), 0)
    // Release: the transaction settles and the caller is answered.
    let _ = gate.release.try_put(())
    assert_eq(submitted.wait().unwrap().length(), 1)
    assert_eq(coordinator.revision(), Ok(1L))
    assert_eq(store.committed_writes.length(), 1)
    // No pending state leaked: the next expectation works immediately.
    let _ = coordinator.submit(command=c_move("t1", 1L))
    assert_eq(coordinator.revision(), Ok(2L))
    coordinator.shutdown()
  })
}

///|
async test "a cancelled caller leaves the accepted submission settling without state leak" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let gate = new_gate()
    let coordinator = ready_scripted(group, store)
    store.persists.push_back(StepGate(gate))
    let submitted = group.spawn(() => {
      coordinator.submit(command=c_create("t1", 0L))
    })
    let _ = gate.entered.get()
    submitted.cancel()
    let _ = submitted.wait() catch { _ => Ok([]) }
    // The pipeline still settles the abandoned submission durably.
    let _ = gate.release.try_put(())
    @async.sleep(1)
    assert_eq(store.persist_attempts, 1)
    assert_eq(store.committed_writes.length(), 1)
    assert_eq(coordinator.revision(), Ok(1L))
    // No pending or deferred entry leaked: the next submission proceeds.
    let _ = coordinator.submit(command=c_move("t1", 1L))
    assert_eq(coordinator.revision(), Ok(2L))
    coordinator.shutdown()
  })
}

///|
async test "wait_ready parks every waiter on completion queues without polling" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let gate = new_gate()
    let seeded = snapshot_of(4L, [task_record("t0", @domain.Created, 3L)], [])
    store.loads.push_back(LoadGate(gate, load_of(seeded)))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    let first = group.spawn(() => coordinator.wait_ready())
    let second = group.spawn(() => coordinator.wait_ready())
    let third = group.spawn(() => coordinator.wait_ready())
    @async.sleep(1)
    // Queries during the load answer Initializing explicitly.
    assert_rejected(coordinator.revision(), Initializing)
    assert_rejected(coordinator.snapshot(), Initializing)
    assert_rejected(coordinator.tasks(), Initializing)
    assert_rejected(coordinator.attempts(), Initializing)
    assert_rejected(coordinator.task(id=cid("t0")), Initializing)
    assert_rejected(coordinator.attempt(id=caid("a1")), Initializing)
    assert_eq(coordinator.status(), Loading)
    // Block its persistence too: readiness must expose revision 4, never 5 early.
    let persist_gate = new_gate()
    store.persists.push_back(StepGate(persist_gate))
    let parked = group.spawn(() => {
      coordinator.submit(command=c_create("t1", 4L))
    })
    @async.sleep(1)
    assert_eq(store.persist_attempts, 0)
    let _ = gate.release.try_put(())
    assert_true(first.wait() is Ok(_))
    assert_true(second.wait() is Ok(_))
    assert_true(third.wait() is Ok(_))
    assert_eq(coordinator.status(), Ready)
    // A late waiter is answered immediately from the committed state.
    assert_true(coordinator.wait_ready() is Ok(_))
    persist_gate.entered.get()
    assert_eq(coordinator.snapshot().unwrap().tasks.length(), 1)
    persist_gate.release.put(())
    assert_eq(parked.wait().unwrap().length(), 1)
    assert_eq(coordinator.revision(), Ok(5L))
    coordinator.shutdown()
  })
}

///|
async test "stale worker reports are no-ops" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    let actor = coordinator.actor.unwrap()
    // A persist report for a ticket that was never issued.
    assert_true(
      actor.tell(Worker(Persisted(ticket=99L, outcome=Ok(())))) is Ok(_),
    )
    // A reload report while no reconciliation runs.
    let foreign = snapshot_of(99L, [task_record("zz", @domain.Done, 9L)], [])
    assert_true(
      actor.tell(Worker(Reloaded(ticket=99L, outcome=Ok(foreign)))) is Ok(_),
    )
    // The board is untouched by all of them.
    assert_eq(coordinator.revision(), Ok(0L))
    assert_eq(coordinator.snapshot().unwrap().tasks.length(), 0)
    coordinator.shutdown()
    assert_eq(coordinator.status(), Stopped)
  })
}

///|
async test "a duplicate persist error during reconciliation is a no-op" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    let landed = snapshot_of(
      1L,
      [
        task_record("t1", @domain.Created, 1000L, created_at_ms=1000L, definition_of_done=[
          "draft",
        ]),
      ],
      [],
    )
    let gate = new_gate()
    store.persists.push_back(StepUncertain("directory fsync lost"))
    store.loads.push_back(LoadGate(gate, load_of(landed)))
    let submitted = group.spawn(() => {
      coordinator.submit(command=c_create("t1", 0L))
    })
    // The reload for ticket 1 is parked mid-reconciliation.
    let _ = gate.entered.get()
    assert_eq(coordinator.status(), Reconciling)
    // A duplicate error for the same ticket while reconciling: no-op.
    let actor = coordinator.actor.unwrap()
    assert_true(
      actor.tell(
        Worker(
          Persisted(ticket=1L, outcome=Err(@store.Injected(@store.Rename))),
        ),
      )
      is Ok(_),
    )
    @async.sleep(1)
    assert_eq(coordinator.status(), Reconciling)
    // The real reconciliation resolves exactly one outcome for the caller.
    let _ = gate.release.try_put(())
    assert_eq(
      submitted.wait(),
      Err(DurabilityUncertain("directory fsync lost")),
    )
    assert_eq(coordinator.status(), Ready)
    assert_eq(coordinator.revision(), Ok(1L))
    coordinator.shutdown()
  })
}

///|
async test "shutdown finishes the in-flight persist, rejects deferred and stops" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let gate = new_gate()
    let coordinator = ready_scripted(group, store)
    store.persists.push_back(StepGate(gate))
    store.persists.push_back(StepOk)
    let a = group.spawn(() => coordinator.submit(command=c_create("t1", 0L)))
    let _ = gate.entered.get()
    let b = group.spawn(() => coordinator.submit(command=c_create("t2", 1L)))
    @async.sleep(1)
    let teardown = group.spawn(() => coordinator.shutdown())
    @async.sleep(1)
    assert_eq(coordinator.status(), Stopping)
    // The teardown cannot finish while the persist is in flight.
    assert_eq(store.persist_attempts, 1)
    let _ = gate.release.try_put(())
    assert_eq(a.wait().unwrap().length(), 1)
    // The deferred submission is rejected explicitly, never persisted.
    assert_eq(b.wait(), Err(Closed))
    let _ = teardown.wait()
    assert_eq(coordinator.status(), Stopped)
    assert_eq(store.persist_attempts, 1)
    assert_eq(store.committed_writes.length(), 1)
    assert_eq(store.committed_writes[0].revision, 1L)
    assert_rejected(coordinator.revision(), Closed)
    assert_rejected(coordinator.submit(command=c_create("t1", 0L)), Closed)
  })
}

///|
async test "concurrent shutdown and submissions stay safe" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let coordinator = ready_scripted(group, store)
    let results : Array[Int] = @async.all([
      () => {
        let outcome = coordinator.submit(command=c_create("t1", 0L))
        if outcome is Ok(_) {
          1
        } else {
          2
        }
      },
      () => {
        coordinator.shutdown()
        3
      },
      () => {
        let outcome = coordinator.submit(command=c_create("t2", 1L))
        if outcome is Ok(_) {
          4
        } else {
          5
        }
      },
    ])
    // The first submission either settles durably (1) or meets the closed
    // admission (2); the last one can only commit late (4) or be rejected
    // explicitly (5).
    assert_true(results[0] == 1 || results[0] == 2)
    assert_true(results[2] == 4 || results[2] == 5)
    assert_eq(coordinator.status(), Stopped)
    // Idempotent second shutdown and closed admission afterwards.
    coordinator.shutdown()
    assert_eq(coordinator.status(), Stopped)
    assert_rejected(coordinator.submit(command=c_create("t1", 0L)), Closed)
    assert_rejected(coordinator.wait_ready(), Closed)
  })
}

///|
async test "shutdown during a load finishes the load and closes cleanly" {
  @async.with_task_group(group => {
    let store = ScriptedBoardStore::new()
    let gate = new_gate()
    let seeded = snapshot_of(2L, [task_record("t0", @domain.Created, 3L)], [])
    store.loads.push_back(LoadGate(gate, load_of(seeded)))
    let coordinator = scripted_coordinator(store)
    coordinator.attach(group~)
    let parked = group.spawn(() => {
      coordinator.submit(command=c_create("t1", 2L))
    })
    @async.sleep(1)
    let teardown = group.spawn(() => coordinator.shutdown())
    @async.sleep(1)
    assert_eq(coordinator.status(), Stopping)
    // The load is still in flight; the restore must finish before exit.
    let _ = gate.release.try_put(())
    // The parked submission was behind the load: shutdown rejects it.
    assert_eq(parked.wait(), Err(Closed))
    let _ = teardown.wait()
    assert_eq(coordinator.status(), Stopped)
    assert_eq(store.persist_attempts, 0)
  })
}
