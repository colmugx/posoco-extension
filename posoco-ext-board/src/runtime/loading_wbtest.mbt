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
async test "read-only server and telemetry operate while domain startup is blocked" {
  let store : LoadingStore = {
    entered: @aqueue.Queue(kind=@aqueue.Blocking(1)),
    release: @aqueue.Queue(kind=@aqueue.Blocking(1)),
  }
  let server : FakeBoardServer = {
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(store~, server~, opener~, now_ms=() => {
    123L
  })
  @async.with_task_group(group => {
    runtime.attach(group)
    store.entered.get()
    assert_eq(runtime.coordinator.status(), @coordinator.Loading)
    assert_true(runtime.coordinator.revision() is Err(Initializing))
    assert_true(runtime.open_board() is Ok(_))
    assert_eq(server.binds, 1)
    assert_eq(opener.opened.length(), 1)
    let event = runtime.publish_telemetry(
      board_revision=0L,
      kind="runtime.warning",
      payload=Json::null(),
    )
    assert_eq(event.seq, 1L)
    assert_eq(runtime.coordinator.status(), @coordinator.Loading)
    store.release.put(())
    assert_true(runtime.coordinator.wait_ready() is Ok(_))
    assert_eq(runtime.coordinator.revision(), Ok(0L))
    assert_eq(runtime.current_seq(), 1L)
    runtime.shutdown()
  })
}

///|
async test "authoritative bootstrap gates on readiness without faking a snapshot" {
  let store : LoadingStore = {
    entered: @aqueue.Queue(kind=@aqueue.Blocking(1)),
    release: @aqueue.Queue(kind=@aqueue.Blocking(1)),
  }
  let server : FakeBoardServer = {
    binds: 0,
    closes: 0,
    alive: false,
    browser: None,
  }
  let opener : FakeBrowserOpener = { opened: [], }
  let runtime = BoardRuntime::with_adapters(store~, server~, opener~)
  @async.with_task_group(group => {
    runtime.attach(group)
    store.entered.get()
    assert_eq(runtime.coordinator.status(), @coordinator.Loading)
    // Telemetry stays live during loading...
    let event = runtime.publish_telemetry(
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
      let outcome = runtime.bootstrap_snapshot()
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
    runtime.shutdown()
  })
}
