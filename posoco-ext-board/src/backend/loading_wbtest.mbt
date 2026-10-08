///|
priv struct LoadingStore {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
impl @store.BoardStore for LoadingStore with fn load(self) {
  self.entered.put(())
  self.release.get()
  Ok({ snapshot: @store.empty_snapshot(), journal: [], })
}

///|
impl @store.BoardStore for LoadingStore with fn persist(
  _self,
  _snapshot,
  _events,
) {
  fail("empty startup must not persist")
}

///|
async test "authoritative bootstrap gates on readiness without faking a snapshot" {
  let store : LoadingStore = {
    entered: @aqueue.Queue(kind=@aqueue.Blocking(1)),
    release: @aqueue.Queue(kind=@aqueue.Blocking(1)),
  }
  let backend = BoardBackend::BoardBackend(store~)
  @async.with_task_group(group => {
    backend.attach(group)
    store.entered.get()
    assert_eq(backend.coordinator.status(), @coordinator.Loading)
    assert_true(backend.coordinator.revision() is Err(Initializing))
    // Telemetry stays live during loading...
    let event = backend.publish_telemetry(
      board_revision=0L,
      kind="runtime.warning",
      payload=Json::null(),
    )
    assert_eq(event.seq, 1L)
    // ...while the bootstrap parks on readiness instead of fabricating an
    // empty-board snapshot.
    let delivered : @aqueue.Queue[Result[@protocol.BoardSnapshot, String]] = @aqueue.Queue(
      kind=@aqueue.Blocking(1),
    )
    let _ = group.spawn(() => {
      let outcome = backend.bootstrap_snapshot()
      delivered.put(outcome)
    })
    @async.sleep(1)
    assert_true(delivered.try_get() is None)
    store.release.put(())
    let frame = delivered.get().unwrap()
    assert_eq(frame.last_seq, 1L)
    assert_eq(frame.board_revision, 0L)
    assert_eq(frame.payload, {
      "board": { "revision": Json::number(0), "tasks": [], "attempts": [] },
      "events": [event.to_json()],
    })
    backend.shutdown()
  })
}

///|
/// Seed one committed board through the same codec the coordinator restores
/// from. Lives in the backend tests because the domain package cannot import
/// the store package without a dependency cycle.
async fn durable_seed() -> &@store.BoardStore {
  let store : &@store.BoardStore = @store.MemoryBoardStore::MemoryBoardStore()
  let created = @domain.BoardDomain::propose(
    @domain.BoardState::BoardState(),
    backend_create("durable", 0L),
  ).unwrap()
  let snapshot = created.next_state.snapshot()
  // The domain accepts exactly what the storage codec accepts.
  let decoded = @store.decode_snapshot(
    @store.encode_snapshot(snapshot).unwrap(),
  ).unwrap()
  assert_eq(decoded, snapshot)
  assert_true(@domain.BoardState::from_snapshot(decoded) is Ok(_))
  assert_eq(store.persist(snapshot, created.events), Ok(()))
  store
}

///|
async test "backend loading restores its own store and stays isolated" {
  let durable = durable_seed()
  let restoring = BoardBackend::BoardBackend(store=durable)
  let isolated = BoardBackend::BoardBackend()
  @async.with_task_group(group => {
    restoring.attach(group)
    isolated.attach(group)
    assert_true(restoring.coordinator.wait_ready() is Ok(_))
    assert_true(isolated.coordinator.wait_ready() is Ok(_))
    // Each backend loaded only its own store.
    assert_eq(restoring.coordinator.revision().unwrap(), 1L)
    assert_eq(restoring.coordinator.tasks().unwrap().length(), 1)
    assert_eq(isolated.coordinator.revision().unwrap(), 0L)
    assert_eq(isolated.coordinator.tasks().unwrap().length(), 0)
    // Mutations stay inside their own backend's board.
    let _ = restoring.coordinator.submit(command=backend_create("next", 1L))
    assert_eq(restoring.coordinator.revision().unwrap(), 2L)
    assert_eq(isolated.coordinator.revision().unwrap(), 0L)
    let _ = isolated.coordinator.submit(command=backend_create("t1", 0L))
    assert_eq(isolated.coordinator.revision().unwrap(), 1L)
    // Only the restoring backend's commits reached the durable store.
    let loaded = durable.load().unwrap().snapshot
    assert_eq(loaded.revision, 2L)
    assert_eq(loaded.tasks.length(), 2)
    restoring.shutdown()
    isolated.shutdown()
  })
}
