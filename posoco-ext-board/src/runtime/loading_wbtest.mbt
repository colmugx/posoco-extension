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
