///|
/// Blackbox headless suite: the whole control plane through the public
/// `BoardBackend` API — commands, snapshots, subscriptions, telemetry,
/// failure, uncertainty, conflict and shutdown — with no transport, no
/// server and no browser opener.

///|
fn headless_create(
  command_id : String,
  id : String,
  rev : Int64,
) -> @protocol.BoardClientCommand {
  {
    command_id,
    name: "board.task.create",
    expected_revision: rev,
    args: {
      "id": id,
      "title": "task \{id}",
      "description": "",
      "priority": "normal",
      "definition_of_done": [],
      "dependencies": [],
    },
  }
}

///|
async test "headless backend serves commands snapshots and subscriptions without transport" {
  let backend = @backend.BoardBackend::BoardBackend(now_ms=() => 1234L)
  @async.with_task_group(group => {
    backend.attach(group)
    // A wire command commits and answers its correlated result.
    assert_eq(backend.handle_command(headless_create("c1", "t1", 0L)), {
      command_id: "c1",
      accepted: true,
      error: None,
      current_revision: Some(1L),
    })
    // The commit is the event stream head.
    let history = backend.event_history()
    assert_eq(history.length(), 1)
    assert_eq(history[0].seq, 1L)
    assert_eq(history[0].board_revision, 1L)
    assert_eq(history[0].kind, "board.task.created")
    assert_eq(backend.current_seq(), 1L)
    // The authoritative snapshot composites board and events.
    let frame = backend.bootstrap_snapshot().unwrap()
    assert_eq(frame.protocol_version, @protocol.protocol_version())
    assert_eq(frame.last_seq, 1L)
    assert_eq(frame.board_revision, 1L)
    assert_eq(frame.payload, {
      "board": {
        "revision": Json::number(1),
        "tasks": [
          {
            "id": "t1",
            "title": "task t1",
            "description": "",
            "stage": "created",
            "priority": "normal",
            "definition_of_done": [],
            "dependencies": [],
            "created_at_ms": Json::number(1234),
            "updated_at_ms": Json::number(1234),
            "ready_since_ms": Json::null(),
          },
        ],
        "attempts": [],
      },
      "events": [history[0].to_json()],
    })
    // Subscription plans are computed atomically with registration.
    let live = backend.subscribe(1L, true)
    assert_eq(live.plan, @backend.Live)
    assert_eq(live.initial(), [])
    backend.unsubscribe(live)
    let stale = backend.subscribe(0L, true)
    assert_eq(stale.plan, @backend.SnapshotRequired)
    assert_eq(stale.initial(), [])
    backend.unsubscribe(stale)
    // A snapshot-required client is bootstrapped exactly like a server
    // would: synchronous registration, awaited backend, installed frame.
    let client = backend.subscribe(0L, false)
    assert_eq(client.plan, @backend.SnapshotRequired)
    client.install_snapshot(backend.bootstrap_snapshot().unwrap())
    assert_eq(client.initial().length(), 1)
    assert_true(
      backend.handle_command(headless_create("c2", "t2", 1L)).accepted,
    )
    guard client.next() is @protocol.Event(created) else {
      fail("expected authoritative command event after snapshot installation")
    }
    assert_eq(created.kind, "board.task.created")
    assert_eq(created.board_revision, 2L)
    assert_eq(created.seq, 2L)
    // Live telemetry shares the same mailbox after the domain event.
    let tick = backend.publish_telemetry(
      board_revision=0L,
      kind="runtime.warning",
      payload=Json::null(),
    )
    guard client.next() is @protocol.Event(event) else {
      fail("expected the live event after the bootstrap")
    }
    assert_eq(event, tick)
    backend.unsubscribe(client)
    assert_eq(backend.subscriber_count(), 0)
    backend.shutdown()
  })
}

///|
async test "headless revision conflict rejects and reports the committed revision" {
  let backend = @backend.BoardBackend::BoardBackend()
  @async.with_task_group(group => {
    backend.attach(group)
    assert_true(
      backend.handle_command(headless_create("c1", "t1", 0L)).accepted,
    )
    // A stale expectation loses exactly once and never mints an event.
    let conflict = backend.handle_command(headless_create("c2", "t2", 0L))
    assert_eq(conflict.accepted, false)
    assert_eq(conflict.error, Some("revision_conflict"))
    assert_eq(conflict.current_revision, Some(1L))
    assert_eq(backend.event_history().length(), 1)
    assert_eq(backend.current_seq(), 1L)
    // The authoritative revision wins on the retry.
    assert_true(
      backend.handle_command(headless_create("c3", "t2", 1L)).accepted,
    )
    assert_eq(backend.event_history().length(), 2)
    backend.shutdown()
  })
}

///|
async test "headless telemetry and commits share one ordered sequence" {
  let backend = @backend.BoardBackend::BoardBackend()
  @async.with_task_group(group => {
    backend.attach(group)
    assert_true(
      backend.handle_command(headless_create("c1", "t1", 0L)).accepted,
    )
    let tick = backend.publish_telemetry(
      board_revision=0L,
      kind="runtime.warning",
      payload=Json::null(),
    )
    assert_eq(tick.seq, 2L)
    assert_eq(tick.board_revision, 0L)
    assert_true(
      backend.handle_command({
        command_id: "c2",
        name: "board.task.update",
        expected_revision: 1L,
        args: { "id": "t1", "title": "renamed" },
      }).accepted,
    )
    // Telemetry advances the stream without moving the durable revision.
    assert_eq(backend.current_seq(), 3L)
    assert_eq(backend.bootstrap_snapshot().unwrap().board_revision, 2L)
    let kinds = backend.event_history().map(event => event.kind)
    assert_eq(kinds, [
      "board.task.created", "runtime.warning", "board.task.updated",
    ])
    backend.shutdown()
  })
}

///|
/// Scripted store for headless failure injection: deterministic counters
/// instead of timing, with an uncertain persist that leaves the attempted
/// snapshot reloadable.
priv struct HeadlessScriptStore {
  mut fail_persists : Int
  mut uncertain_persists : Int
  mut landed : @store.BoardLoad?
}

///|
impl @store.BoardStore for HeadlessScriptStore with fn load(self) {
  match self.landed {
    Some(loaded) => Ok(loaded)
    None => Ok({ snapshot: @store.empty_snapshot(), journal: [], })
  }
}

///|
impl @store.BoardStore for HeadlessScriptStore with fn persist(
  self,
  snapshot,
  _events,
) {
  if self.fail_persists > 0 {
    self.fail_persists = self.fail_persists - 1
    return Err(@store.Injected(@store.TempWrite))
  }
  if self.uncertain_persists > 0 {
    self.uncertain_persists = self.uncertain_persists - 1
    self.landed = Some({ snapshot: snapshot.copy_detached(), journal: [], })
    return Err(@store.DurabilityUncertain("injected fsync loss"))
  }
  self.landed = None
  Ok(())
}

///|
async test "headless persistence failure answers without minting an event" {
  let store : HeadlessScriptStore = {
    fail_persists: 1,
    uncertain_persists: 0,
    landed: None,
  }
  let backend = @backend.BoardBackend::BoardBackend(store~)
  @async.with_task_group(group => {
    backend.attach(group)
    let rejected = backend.handle_command(headless_create("doomed", "t1", 0L))
    assert_eq(rejected.accepted, false)
    assert_eq(rejected.error, Some("persistence_failed"))
    assert_eq(rejected.current_revision, Some(0L))
    assert_eq(backend.event_history(), [])
    assert_eq(backend.current_seq(), 0L)
    // The backend stays ready: the retried write commits.
    assert_true(
      backend.handle_command(headless_create("retried", "t1", 0L)).accepted,
    )
    assert_eq(backend.event_history().length(), 1)
    backend.shutdown()
  })
}

///|
async test "headless uncertain durability commits once and answers false with the new revision" {
  let store : HeadlessScriptStore = {
    fail_persists: 0,
    uncertain_persists: 1,
    landed: None,
  }
  let backend = @backend.BoardBackend::BoardBackend(store~, now_ms=() => 1234L)
  @async.with_task_group(group => {
    backend.attach(group)
    let uncertain = backend.handle_command(headless_create("t1", "t1", 0L))
    // The reload found the candidate: it committed exactly once and its
    // event streams, but the caller must still refresh before retrying.
    assert_eq(uncertain.accepted, false)
    assert_eq(uncertain.error, Some("durability_uncertain"))
    assert_eq(uncertain.current_revision, Some(1L))
    assert_eq(backend.event_history().length(), 1)
    assert_eq(backend.event_history()[0].kind, "board.task.created")
    assert_eq(backend.bootstrap_snapshot().unwrap().board_revision, 1L)
    backend.shutdown()
  })
}

///|
async test "headless shutdown closes admission and keeps answers wire-safe" {
  let backend = @backend.BoardBackend::BoardBackend()
  @async.with_task_group(group => {
    backend.attach(group)
    assert_true(
      backend.handle_command(headless_create("c1", "t1", 0L)).accepted,
    )
    backend.shutdown()
    let closed = backend.handle_command(headless_create("c2", "t2", 1L))
    assert_eq(closed.accepted, false)
    assert_eq(closed.error, Some("board_unavailable"))
    assert_eq(closed.current_revision, None)
    // No fabricated snapshot after shutdown.
    assert_eq(backend.bootstrap_snapshot(), Err("snapshot_unavailable"))
    // The stream and its subscriptions stay inspectable.
    assert_eq(backend.current_seq(), 1L)
    assert_eq(backend.event_history().length(), 1)
    backend.shutdown()
  })
}
