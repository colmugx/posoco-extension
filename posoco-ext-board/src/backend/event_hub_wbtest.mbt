///|
test "event hub mints monotonic seq" {
  let backend = BoardBackend::BoardBackend(event_buffer=8)
  let first = backend.publish_telemetry(
    board_revision=0L,
    kind="turn.started",
    payload=Json::null(),
  )
  let second = backend.publish_telemetry(
    board_revision=0L,
    kind="assistant.delta",
    payload=Json::string("x"),
  )
  assert_eq(first.seq, 1L)
  assert_eq(second.seq, 2L)
  assert_eq(backend.current_seq(), 2L)
}

///|
test "event seq advances independently from board revision" {
  let backend = BoardBackend::BoardBackend(event_buffer=8)
  let a = backend.publish_telemetry(
    board_revision=7L,
    kind="assistant.delta",
    payload=Json::string("a"),
  )
  let b = backend.publish_telemetry(
    board_revision=7L,
    kind="assistant.delta",
    payload=Json::string("b"),
  )
  let c = backend.publish_telemetry(
    board_revision=8L,
    kind="task.transitioned",
    payload=Json::null(),
  )
  assert_eq(a.seq, 1L)
  assert_eq(b.seq, 2L)
  assert_eq(c.seq, 3L)
  assert_eq(a.board_revision, 7L)
  assert_eq(b.board_revision, 7L)
  assert_eq(c.board_revision, 8L)
}

///|
test "event hub evicts oldest events at capacity" {
  let backend = BoardBackend::BoardBackend(event_buffer=2)
  for i in 0..<3 {
    let _ = backend.publish_telemetry(
      board_revision=0L,
      kind="tick",
      payload=Json::number(i.to_double()),
    )
  }
  let history = backend.event_history()
  assert_eq(history.length(), 2)
  assert_eq(history[0].seq, 2L)
  assert_eq(history[1].seq, 3L)
  assert_eq(backend.hub.history_since(2L).map(event => event.seq), [3L])
}

///|
test "backend constructor plumbs capacities into the owned hub" {
  let backend = BoardBackend::BoardBackend(event_buffer=8, client_queue_depth=2)
  assert_eq(backend.hub.capacity, 8)
  assert_eq(backend.hub.client_queue_depth, 2)
}

///|
async test "published and inspected events are detached down to the JSON tree" {
  let backend = BoardBackend::BoardBackend(event_buffer=8)
  let payload : Map[String, Json] = { "text": "mutable" }
  let _ = backend.publish_telemetry(
    board_revision=0L,
    kind="tick",
    payload=Json::object(payload),
  )
  payload["text"] = "mutated after publish"
  let first = backend.event_history()
  assert_eq(first[0].payload, { "text": "mutable" })
  // Mutating the returned inspection copy cannot reach the retained stream.
  match first[0].payload {
    Json::Object(fields) => fields["text"] = "mutated after read"
    _ => fail("expected an object payload")
  }
  assert_eq(backend.event_history()[0].payload, { "text": "mutable" })
  // Subscriptions receive the same detached copy.
  let client = backend.subscribe(0L, true)
  let _ = backend.publish_telemetry(board_revision=0L, kind="tick", payload={
    "text": "live",
  })
  match client.next() {
    @protocol.Event(event) => assert_eq(event.payload, { "text": "live" })
    _ => fail("expected a live event")
  }
  backend.unsubscribe(client)
}

///|
test "replay boundaries empty current zero covered gap and future" {
  let backend = BoardBackend::BoardBackend(event_buffer=2)
  let fresh_empty = backend.subscribe(0L, false)
  assert_eq(fresh_empty.plan, SnapshotRequired)
  backend.unsubscribe(fresh_empty)
  let empty = backend.subscribe(0L, true)
  assert_eq(empty.plan, Live)
  assert_eq(empty.initial(), [])
  backend.unsubscribe(empty)
  let future_empty = backend.subscribe(1L, true)
  // A cursor ahead of the head requires an authoritative snapshot; the hub
  // never fabricates one.
  assert_eq(future_empty.plan, SnapshotRequired)
  assert_eq(future_empty.initial(), [])
  backend.unsubscribe(future_empty)
  let first = backend_tick(backend)
  let zero = backend.subscribe(0L, true)
  assert_eq(zero.plan, SnapshotRequired)
  assert_eq(zero.initial(), [])
  backend.unsubscribe(zero)
  let second = backend_tick(backend)
  let third = backend_tick(backend)
  let covered = backend.subscribe(first.seq, true)
  assert_eq(covered.plan, Replay([second, third]))
  assert_eq(covered.initial(), [@protocol.Event(second), @protocol.Event(third)])
  backend.unsubscribe(covered)
  let current = backend.subscribe(3L, true)
  assert_eq(current.plan, Live)
  assert_eq(current.initial(), [])
  backend.unsubscribe(current)
  let fresh_at_head = backend.subscribe(3L, false)
  assert_eq(fresh_at_head.plan, SnapshotRequired)
  assert_eq(fresh_at_head.initial(), [])
  backend.unsubscribe(fresh_at_head)
  let fourth = backend_tick(backend)
  assert_eq(fourth.seq, 4L)
  // Zero with existing events, a gap below the retained head and a future
  // cursor all demand the authoritative snapshot.
  for cursor in [0L, 1L, 5L] {
    let reset = backend.subscribe(cursor, true)
    assert_eq(reset.plan, SnapshotRequired)
    assert_eq(reset.initial(), [])
    backend.unsubscribe(reset)
  }
  assert_eq(backend.subscriber_count(), 0)
}

///|
test "history_through bounds the contiguous retained tail" {
  let backend = BoardBackend::BoardBackend(event_buffer=4)
  for _ in 0..<3 {
    let _ = backend_tick(backend)
  }
  assert_eq(backend.hub.history_through(2L).map(event => event.seq), [1L, 2L])
  assert_eq(backend.hub.history_through(0L).length(), 0)
  assert_eq(backend.hub.history_through(99L).length(), 3)
}

///|
async test "snapshot plan installs the authoritative frame and the sender skips stale live" {
  let backend = BoardBackend::BoardBackend(event_buffer=8, client_queue_depth=8)
  for _ in 0..<2 {
    let _ = backend_tick(backend)
  }
  let client = backend.subscribe(0L, true)
  defer backend.unsubscribe(client)
  assert_eq(client.plan, SnapshotRequired)
  // Live events accumulate in the mailbox while the authoritative
  // bootstrap is awaited.
  let _third = backend_tick(backend)
  let _fourth = backend_tick(backend)
  client.install_snapshot({
    protocol_version: @protocol.protocol_version(),
    last_seq: 4L,
    board_revision: 0L,
    payload: { "events": [] },
  })
  assert_eq(client.baseline_seq, 4L)
  let fifth = backend_tick(backend)
  assert_eq(client.next(), @protocol.Event(fifth))
  assert_eq(client.initial(), [
    @protocol.Snapshot({
      protocol_version: @protocol.protocol_version(),
      last_seq: 4L,
      board_revision: 0L,
      payload: { "events": [] },
    }),
  ])
}

///|
async test "atomic replay then live never fills mailbox with replay" {
  let backend = BoardBackend::BoardBackend(event_buffer=8, client_queue_depth=2)
  for _ in 0..<5 {
    let _ = backend_tick(backend)
  }
  let client = backend.subscribe(1L, true)
  assert_true(client.plan is Replay(_))
  assert_eq(client.initial().length(), 4)
  assert_eq(client.resync_required(), None)
  let live = backend_tick(backend)
  assert_eq(client.initial().length(), 4)
  assert_eq(client.next(), @protocol.Event(live))
  let snapshot = backend.subscribe(0L, true)
  // Zero cursor demands the authoritative snapshot; no frame is fabricated
  // and the live frames keep flowing after registration.
  assert_eq(snapshot.plan, SnapshotRequired)
  assert_eq(snapshot.initial(), [])
  let next = backend_tick(backend)
  assert_eq(snapshot.next(), @protocol.Event(next))
  backend.unsubscribe(client)
  backend.unsubscribe(snapshot)
  assert_eq(backend.subscriber_count(), 0)
}

///|
async test "depth two overflow is explicit terminal and independent" {
  let backend = BoardBackend::BoardBackend(client_queue_depth=2)
  let slow = backend.subscribe(0L, true)
  let fast = backend.subscribe(0L, true)
  for _ in 0..<3 {
    let event = backend_tick(backend)
    assert_eq(fast.next(), @protocol.Event(event))
  }
  let expected = @protocol.ResyncRequired(
    reason="client_queue_overflow",
    current_seq=3L,
  )
  assert_eq(slow.resync_required(), Some(expected))
  assert_eq(slow.next(), expected)
  let event = backend_tick(backend)
  assert_eq(fast.next(), @protocol.Event(event))
  assert_eq(fast.resync_required(), None)
  assert_eq(
    slow.next(),
    @protocol.ResyncRequired(reason="client_queue_overflow", current_seq=4L),
  )
  backend.unsubscribe(slow)
  backend.unsubscribe(slow)
  assert_eq(backend.subscriber_count(), 1)
  backend.unsubscribe(fast)
  assert_eq(backend.subscriber_count(), 0)
  assert_true(fast.closed)
  let closed = fast.next() catch { _ => return }
  let _ = closed
  fail("closed mailbox must not deliver events")
}

///|
async test "overflow before sender sends resync instead of initial or queued frames" {
  let backend = BoardBackend::BoardBackend(client_queue_depth=2)
  let _ = backend_tick(backend)
  let client = backend.subscribe(0L, true)
  defer backend.unsubscribe(client)
  for _ in 0..<3 {
    let _ = backend_tick(backend)
  }
  let sent : Array[@protocol.BoardServerFrame] = []
  @async.with_timeout(1000, () => client.pump(frame => sent.push(frame)))
  assert_eq(sent, [
    @protocol.ResyncRequired(reason="client_queue_overflow", current_seq=4L),
  ])
}

///|
async test "overflow cancels and joins a blocked bootstrap writer" {
  let backend = BoardBackend::BoardBackend(client_queue_depth=2)
  let _ = backend_tick(backend)
  let client = backend.subscribe(0L, true)
  defer backend.unsubscribe(client)
  client.install_snapshot({
    protocol_version: @protocol.protocol_version(),
    last_seq: 1L,
    board_revision: 0L,
    payload: { "events": [] },
  })
  let entered : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
  let blocked : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
  let mut exited = false
  let mut sends = 0
  @async.with_timeout(1000, () => {
    @async.with_task_group(group => {
      let sender = group.spawn(() => {
        client.pump(_frame => {
          sends += 1
          defer {
            exited = true
          }
          entered.put(())
          blocked.get()
        })
      })
      entered.get()
      for _ in 0..<3 {
        let _ = backend_tick(backend)
      }
      sender.wait()
      assert_true(exited)
      assert_eq(sends, 1)
    })
  })
}

///|
async test "cancelling sender joins blocked writer and unsubscribes" {
  let backend = BoardBackend::BoardBackend(client_queue_depth=2)
  let entered : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
  let blocked : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
  let mut exited = false
  @async.with_timeout(1000, () => {
    @async.with_task_group(group => {
      let sender = group.spawn(() => {
        let client = backend.subscribe(0L, true)
        defer backend.unsubscribe(client)
        let _ = backend_tick(backend)
        client.pump(_frame => {
          defer {
            exited = true
          }
          entered.put(())
          blocked.get()
        })
      })
      entered.get()
      sender.cancel()
      sender.wait() catch {
        _ => ()
      }
      assert_true(exited)
      assert_eq(backend.subscriber_count(), 0)
    })
  })
}
