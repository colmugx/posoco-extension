///|
/// Durable headless Board service. Hosts consume detached snapshots and
/// subscriptions without owning its hub, coordinator or mutation clock.
pub struct BoardBackend {
  priv hub : BoardEventHub
  priv coordinator : @coordinator.BoardCoordinator
  priv now_ms : () -> Int64
}

///|
/// `store` supplies the durable board (default: an empty `MemoryBoardStore`)
/// and `now_ms` the recovery and committed timestamps (default:
/// deterministic 0). Every committed event is projected into the owned hub
/// before the committing caller is answered, and the coordinator's
/// `stream_cursor` reads the live hub head, so every stream boundary is an
/// actual hub position.
///
/// ```mbt check
/// test {
///   let backend = @backend.BoardBackend()
///   let subscription = backend.subscribe(0L, false)
///   assert_eq(subscription.plan, @backend.SnapshotRequired)
///   assert_eq(backend.current_seq(), 0L)
///   backend.unsubscribe(subscription)
/// }
/// ```
pub fn BoardBackend::BoardBackend(
  event_buffer? : Int = 4096,
  client_queue_depth? : Int = 256,
  store? : &@store.BoardStore = @store.MemoryBoardStore::MemoryBoardStore(),
  now_ms? : () -> Int64 = () => 0L,
) -> BoardBackend {
  let hub = BoardEventHub(capacity=event_buffer, client_queue_depth~)
  {
    hub,
    coordinator: @coordinator.BoardCoordinator::BoardCoordinator(
      store~,
      now_ms~,
      on_commit=(snapshot, events) => {
        board_publish_commit(hub, snapshot, events)
      },
      stream_cursor=() => hub.current_seq(),
    ),
    now_ms,
  }
}

///|
/// Bind the durable coordinator to a host-owned structured-concurrency
/// scope. Repeated attach is idempotent; no Agent or Posoco Tasks
/// capability is attached.
pub fn BoardBackend::attach(
  self : BoardBackend,
  group : @async.TaskGroup[Unit],
) -> Unit {
  self.coordinator.attach(group~)
}

///|
/// Final teardown: close coordinator admission and join its drained loop.
/// Idempotent.
pub async fn BoardBackend::shutdown(self : BoardBackend) -> Unit {
  self.coordinator.shutdown()
}

///|
/// Subscribe one client at `last_seq` with an explicit snapshot-ownership
/// flag. The returned plan is computed atomically with registration; a
/// `SnapshotRequired` plan must be fulfilled by installing
/// `bootstrap_snapshot` through `install_snapshot`.
pub fn BoardBackend::subscribe(
  self : BoardBackend,
  last_seq : Int64,
  has_board_snapshot : Bool,
) -> BoardSubscription {
  self.hub.subscribe(last_seq, has_board_snapshot)
}

///|
pub fn BoardBackend::unsubscribe(
  self : BoardBackend,
  client : BoardSubscription,
) -> Unit {
  self.hub.unsubscribe(client)
}

///|
/// Deliver one frame to a single live subscription without publishing it
/// into the retained stream: correlated command results and per-connection
/// markers are scoped to the issuing client only.
pub fn BoardBackend::enqueue_local(
  self : BoardBackend,
  client : BoardSubscription,
  frame : @protocol.BoardServerFrame,
) -> Unit {
  client.enqueue(frame, self.hub.current_seq())
}

///|
pub fn BoardBackend::current_seq(self : BoardBackend) -> Int64 {
  self.hub.current_seq()
}

///|
/// Detached telemetry history: the returned events share no mutable state
/// with the retained stream.
pub fn BoardBackend::event_history(
  self : BoardBackend,
) -> Array[@protocol.BoardWireEvent] {
  self.hub.history()
}

///|
/// Publish display telemetry into the shared stream. The hub mints the
/// transport sequence; publishing never awaits and never fails. The
/// returned event is detached from the retained copy.
pub fn BoardBackend::publish_telemetry(
  self : BoardBackend,
  board_revision~ : Int64,
  kind~ : String,
  scope? : @protocol.BoardEventScope? = None,
  payload~ : Json,
) -> @protocol.BoardWireEvent {
  self.hub.publish(board_revision~, kind~, scope~, payload~)
}

///|
/// Number of live subscriptions, for tests and host diagnostics.
pub fn BoardBackend::subscriber_count(self : BoardBackend) -> Int {
  self.hub.subscriber_count()
}
