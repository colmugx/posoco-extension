///|
/// Store scripted for bootstrap integration tests: every persist parks on
/// one gate, carries a scripted outcome and the reload always returns the
/// store's durable board.
priv struct GatedPersistStore {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
  mut gated : Bool
  mut persist_error : @store.BoardStoreError?
  mut durable : @domain.BoardStateSnapshot
}

///|
fn GatedPersistStore::GatedPersistStore(
  durable? : @domain.BoardStateSnapshot = @store.empty_snapshot(),
) -> GatedPersistStore {
  {
    entered: @aqueue.Queue(kind=@aqueue.Blocking(1)),
    release: @aqueue.Queue(kind=@aqueue.Blocking(1)),
    gated: true,
    persist_error: None,
    durable,
  }
}

///|
impl @store.BoardStore for GatedPersistStore with fn load(self) {
  Ok({ snapshot: self.durable.copy_detached(), journal: [], })
}

///|
impl @store.BoardStore for GatedPersistStore with fn persist(
  self,
  snapshot,
  _events,
) {
  if self.gated {
    self.entered.put(())
    self.release.get()
  }
  match self.persist_error {
    Some(error) => Err(error)
    None => {
      self.durable = snapshot.copy_detached()
      Ok(())
    }
  }
}

///|
/// Store whose startup load always fails: the coordinator cannot establish
/// durable state and the bootstrap must refuse honestly.
priv struct FailingLoadStore {
  error : @store.BoardStoreError
}

///|
impl @store.BoardStore for FailingLoadStore with fn load(self) {
  Err(self.error)
}

///|
impl @store.BoardStore for FailingLoadStore with fn persist(
  _self,
  _snapshot,
  _events,
) {
  fail("a failed load must never reach persist")
}

///|
fn bootstrap_server() -> FakeBoardServer {
  { binds: 0, closes: 0, alive: false, browser: None, }
}

///|
async test "gated persist failure publishes nothing and the retry streams once" {
  let store = GatedPersistStore::GatedPersistStore()
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(
    server=bootstrap_server(),
    opener~,
    store~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    assert_eq(runtime.current_seq(), 0L)
    assert_eq(runtime.coordinator.stream_cursor(), 0L)
    let submitted = group.spawn(() => {
      runtime.coordinator.submit(command=runtime_create("t1", 0L))
    })
    store.entered.get()
    // The candidate is parked at the store: no commit, no publication, no
    // stream advance.
    assert_eq(runtime.current_seq(), 0L)
    assert_eq(runtime.coordinator.stream_cursor(), 0L)
    assert_eq(runtime.coordinator.revision(), Ok(0L))
    store.persist_error = Some(@store.Injected(@store.JournalFsync))
    store.release.put(())
    assert_eq(
      submitted.wait(),
      Err(PersistFailed(@store.Injected(@store.JournalFsync))),
    )
    assert_eq(runtime.current_seq(), 0L)
    assert_eq(runtime.coordinator.revision(), Ok(0L))
    assert_eq(runtime.event_history().length(), 0)
    // The old expected revision still wins, and the settled commit streams
    // exactly once.
    store.gated = false
    store.persist_error = None
    assert_eq(
      runtime.coordinator
      .submit(command=runtime_create("t1", 0L))
      .unwrap()
      .length(),
      1,
    )
    assert_eq(runtime.current_seq(), 1L)
    assert_eq(runtime.coordinator.stream_cursor(), 1L)
    assert_eq(runtime.event_history().length(), 1)
    assert_eq(runtime.event_history()[0].kind, "board.task.created")
    assert_eq(runtime.event_history()[0].board_revision, 1L)
    runtime.shutdown()
  })
}

///|
async test "uncertain persist resolving to the candidate streams its events exactly once" {
  let store = GatedPersistStore::GatedPersistStore()
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(
    server=bootstrap_server(),
    opener~,
    store~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    store.persist_error = Some(
      @store.DurabilityUncertain("rename visibility lost"),
    )
    let submitted = group.spawn(() => {
      runtime.coordinator.submit(command=runtime_create("t1", 0L))
    })
    store.entered.get()
    // The write had landed after all: the authoritative board is the
    // candidate.
    store.durable = @domain.BoardDomain::propose(
      @domain.BoardState::BoardState(),
      runtime_create("t1", 0L),
    ).unwrap().next_state.snapshot()
    store.release.put(())
    assert_eq(
      submitted.wait(),
      Err(DurabilityUncertain("rename visibility lost")),
    )
    // The adopted candidate committed and streamed exactly once, even
    // though the caller learned the outcome was uncertain.
    assert_eq(runtime.coordinator.revision(), Ok(1L))
    assert_eq(runtime.coordinator.stream_cursor(), 1L)
    assert_eq(runtime.current_seq(), 1L)
    assert_eq(runtime.event_history().length(), 1)
    assert_eq(runtime.event_history()[0].kind, "board.task.created")
    assert_eq(runtime.event_history()[0].board_revision, 1L)
    runtime.shutdown()
  })
}

///|
async test "uncertain persist resolving to the old board streams nothing" {
  let store = GatedPersistStore::GatedPersistStore()
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(
    server=bootstrap_server(),
    opener~,
    store~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    store.persist_error = Some(@store.DurabilityUncertain("journal lost"))
    let submitted = group.spawn(() => {
      runtime.coordinator.submit(command=runtime_create("t1", 0L))
    })
    store.entered.get()
    // The write never became visible: the reload returns the old board.
    store.release.put(())
    assert_true(submitted.wait() is Err(DurabilityUncertain(_)))
    assert_eq(runtime.coordinator.revision(), Ok(0L))
    assert_eq(runtime.coordinator.stream_cursor(), 0L)
    assert_eq(runtime.current_seq(), 0L)
    assert_eq(runtime.event_history().length(), 0)
    // The discarded candidate left no stream residue; the retry commits on
    // the old revision and streams once.
    store.gated = false
    store.persist_error = None
    assert_true(
      runtime.coordinator.submit(command=runtime_create("t1", 0L)) is Ok(_),
    )
    assert_eq(runtime.coordinator.revision(), Ok(1L))
    assert_eq(runtime.current_seq(), 1L)
    assert_eq(runtime.event_history().length(), 1)
    runtime.shutdown()
  })
}

///|
async test "stale stream boundary is never served and a fresh boundary composites" {
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(
    event_buffer=2,
    server=bootstrap_server(),
    opener~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    assert_true(
      runtime.coordinator.submit(command=runtime_create("t1", 0L)) is Ok(_),
    )
    let stale = runtime.coordinator.stream_snapshot().unwrap()
    assert_eq(stale.stream_seq, 1L)
    let mut expected = 1L
    for id in ["t2", "t3", "t4"] {
      assert_true(
        runtime.coordinator.submit(command=runtime_create(id, expected))
        is Ok(_),
      )
      expected = expected + 1L
    }
    // The bounded history evicted events 1 and 2, so the retained suffix
    // ending at the stale boundary no longer exists: it is never composed,
    // and no fabricated empty snapshot is served for cursor 1.
    assert_eq(runtime.event_history().map(event => event.seq), [3L, 4L])
    assert_true(runtime.build_composite(stale) is None)
    // A fresh boundary composites the committed board with every retained
    // event up to and ending exactly at that boundary.
    let fresh = runtime.coordinator.stream_snapshot().unwrap()
    let frame = runtime.build_composite(fresh).unwrap()
    assert_eq(fresh.stream_seq, 4L)
    assert_eq(frame.last_seq, 4L)
    assert_eq(frame.board_revision, 4L)
    assert_eq(frame.protocol_version, @protocol.protocol_version())
    assert_eq(frame.payload, {
      "board": @protocol.snapshot_to_json(fresh.board_snapshot),
      "events": runtime.event_history().map(event => event.to_json()),
    })
    runtime.shutdown()
  })
}

///|
async test "answered boundaries are exact hub positions and survive later commits" {
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(server=bootstrap_server(), opener~)
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    // Five committed revisions interleaved with telemetry: the boundary of
    // the fifth commit's answer is hub sequence 20.
    let mut expected = 0L
    for i in 0..<5 {
      assert_true(
        runtime.coordinator.submit(command=runtime_create("t\{i}", expected))
        is Ok(_),
      )
      expected = expected + 1L
      let _ = runtime.publish_telemetry(
        board_revision=0L,
        kind="runtime.warning",
        payload=Json::null(),
      )
      let _ = runtime.publish_telemetry(
        board_revision=0L,
        kind="runtime.warning",
        payload=Json::null(),
      )
      let _ = runtime.publish_telemetry(
        board_revision=0L,
        kind="runtime.warning",
        payload=Json::null(),
      )
    }
    assert_eq(runtime.current_seq(), 20L)
    let boundary = runtime.coordinator.stream_snapshot().unwrap()
    assert_eq(boundary.board_snapshot.revision, 5L)
    assert_eq(boundary.stream_seq, 20L)
    let old = runtime.build_composite(boundary).unwrap()
    assert_eq(old.last_seq, 20L)
    assert_eq(old.board_revision, 5L)
    // A later commit moves both the revision and the hub head; the answered
    // boundary is retained verbatim, not recomputed.
    assert_true(
      runtime.coordinator.submit(command=runtime_create("t5", 5L)) is Ok(_),
    )
    assert_eq(runtime.current_seq(), 21L)
    assert_eq(boundary.stream_seq, 20L)
    assert_eq(runtime.build_composite(boundary).unwrap().last_seq, 20L)
    let next = runtime.coordinator.stream_snapshot().unwrap()
    assert_eq(next.board_snapshot.revision, 6L)
    assert_eq(next.stream_seq, 21L)
    let frame = runtime.build_composite(next).unwrap()
    assert_eq(frame.last_seq, 21L)
    assert_eq(frame.board_revision, 6L)
    runtime.shutdown()
  })
}

///|
async test "board-only bootstrap streams the retained telemetry suffix" {
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(server=bootstrap_server(), opener~)
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    let tick = runtime.publish_telemetry(
      board_revision=0L,
      kind="runtime.warning",
      payload=Json::null(),
    )
    let frame = runtime.bootstrap_snapshot().unwrap()
    assert_eq(frame.last_seq, 1L)
    assert_eq(frame.board_revision, 0L)
    assert_eq(frame.payload, {
      "board": {
        "revision": Json::number(0),
        "tasks": Json::array([]),
        "attempts": Json::array([]),
      },
      "events": [tick.to_json()],
    })
    runtime.shutdown()
  })
}

///|
async test "telemetry-only overflow still composites from the retained boundary" {
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(
    event_buffer=2,
    server=bootstrap_server(),
    opener~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    for _ in 0..<4 {
      let _ = runtime.publish_telemetry(
        board_revision=0L,
        kind="runtime.warning",
        payload=Json::null(),
      )
    }
    // No commit ever moved the stream boundary, so the initial board is
    // boundary-independent and the oldest retained boundary serves.
    let frame = runtime.bootstrap_snapshot().unwrap()
    assert_eq(frame.last_seq, 4L)
    assert_eq(frame.board_revision, 0L)
    assert_eq(frame.payload, {
      "board": { "revision": Json::number(0), "tasks": [], "attempts": [] },
      "events": runtime.event_history().map(event => event.to_json()),
    })
    runtime.shutdown()
  })
}

///|
async test "restore failure refuses the bootstrap with a wire-safe reason" {
  let store : &@store.BoardStore = FailingLoadStore::{
    error: @store.Io("board snapshot corrupt"),
  }
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(
    server=bootstrap_server(),
    opener~,
    store~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    assert_true(runtime.coordinator.wait_ready() is Err(RestoreFailed(_)))
    // No fabricated empty board, no store detail on the wire.
    assert_eq(runtime.bootstrap_snapshot(), Err("snapshot_unavailable"))
    runtime.shutdown()
  })
}
