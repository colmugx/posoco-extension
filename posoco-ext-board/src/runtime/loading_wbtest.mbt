///|
/// Presentation stays available while the backend's durable startup is
/// blocked. The readiness-gating of the bootstrap itself is covered by the
/// backend tests; this file proves the runtime lifecycle and telemetry do
/// not wait on it.
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
fn loading_store() -> LoadingStore {
  {
    entered: @aqueue.Queue(kind=@aqueue.Blocking(1)),
    release: @aqueue.Queue(kind=@aqueue.Blocking(1)),
  }
}

///|
async test "read-only server and telemetry operate while domain startup is blocked" {
  let store = loading_store()
  let server : FakeBoardServer = lifecycle_server()
  let opener = lifecycle_opener()
  let runtime = BoardRuntime::with_adapters(
    backend=@backend.BoardBackend::BoardBackend(store~, now_ms=() => 123L),
    server~,
    opener~,
  )
  @async.with_task_group(group => {
    runtime.attach(group)
    store.entered.get()
    assert_true(runtime.open_board() is Ok(_))
    assert_eq(server.binds, 1)
    assert_eq(opener.opened.length(), 1)
    // Commands submitted while loading park with their transaction until
    // readiness instead of fabricating answers; the explicit Initializing
    // phase is asserted on the backend level.
    let event = runtime
      .backend()
      .publish_telemetry(
        board_revision=0L,
        kind="runtime.warning",
        payload=Json::null(),
      )
    assert_eq(event.seq, 1L)
    store.release.put(())
    // The bootstrap parks on readiness, then answers the hub boundary.
    let frame = runtime.backend().bootstrap_snapshot().unwrap()
    assert_eq(frame.last_seq, 1L)
    assert_eq(frame.board_revision, 0L)
    assert_eq(runtime.current_seq(), 1L)
    runtime.shutdown()
  })
}
