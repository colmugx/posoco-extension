///|
fn hub_tick(hub : BoardEventHub) -> @protocol.BoardWireEvent {
  hub.publish(board_revision=0L, kind="assistant.delta", payload={
    "text": "[redacted]",
  })
}

///|
test "replay boundaries empty current zero covered gap and future" {
  let hub = BoardEventHub(capacity=2)
  let fresh_empty = hub.subscribe(0L, false)
  assert_eq(fresh_empty.plan, SnapshotRequired)
  hub.unsubscribe(fresh_empty)
  let empty = hub.subscribe(0L, true)
  assert_eq(empty.plan, Live)
  assert_eq(empty.initial(), [])
  hub.unsubscribe(empty)
  let future_empty = hub.subscribe(1L, true)
  // A cursor ahead of the head requires an authoritative snapshot; the hub
  // never fabricates one.
  assert_eq(future_empty.plan, SnapshotRequired)
  assert_eq(future_empty.initial(), [])
  hub.unsubscribe(future_empty)
  let first = hub_tick(hub)
  let zero = hub.subscribe(0L, true)
  assert_eq(zero.plan, SnapshotRequired)
  assert_eq(zero.initial(), [])
  hub.unsubscribe(zero)
  let second = hub_tick(hub)
  let third = hub_tick(hub)
  let covered = hub.subscribe(first.seq, true)
  assert_eq(covered.plan, Replay([second, third]))
  assert_eq(covered.initial(), [@protocol.Event(second), @protocol.Event(third)])
  hub.unsubscribe(covered)
  let current = hub.subscribe(3L, true)
  assert_eq(current.plan, Live)
  assert_eq(current.initial(), [])
  hub.unsubscribe(current)
  let fresh_at_head = hub.subscribe(3L, false)
  assert_eq(fresh_at_head.plan, SnapshotRequired)
  assert_eq(fresh_at_head.initial(), [])
  hub.unsubscribe(fresh_at_head)
  let fourth = hub_tick(hub)
  assert_eq(fourth.seq, 4L)
  // Zero with existing events, a gap below the retained head and a future
  // cursor all demand the authoritative snapshot.
  for cursor in [0L, 1L, 5L] {
    let reset = hub.subscribe(cursor, true)
    assert_eq(reset.plan, SnapshotRequired)
    assert_eq(reset.initial(), [])
    hub.unsubscribe(reset)
  }
  assert_eq(hub.subscriber_count(), 0)
}

///|
test "history_through bounds the contiguous retained tail" {
  let hub = BoardEventHub(capacity=4)
  for _ in 0..<3 {
    let _ = hub_tick(hub)
  }
  assert_eq(hub.history_through(2L).map(event => event.seq), [1L, 2L])
  assert_eq(hub.history_through(0L).length(), 0)
  assert_eq(hub.history_through(99L).length(), 3)
}

///|
async test "snapshot plan installs the authoritative frame and the sender skips stale live" {
  let hub = BoardEventHub(capacity=8, client_queue_depth=8)
  for _ in 0..<2 {
    let _ = hub_tick(hub)
  }
  let client = hub.subscribe(0L, true)
  defer hub.unsubscribe(client)
  assert_eq(client.plan, SnapshotRequired)
  // Live events accumulate in the mailbox while the authoritative
  // bootstrap is awaited.
  let _third = hub_tick(hub)
  let _fourth = hub_tick(hub)
  client.install_snapshot({
    protocol_version: @protocol.protocol_version(),
    last_seq: 4L,
    board_revision: 0L,
    payload: { "events": [] },
  })
  assert_eq(client.baseline_seq, 4L)
  let fifth = hub_tick(hub)
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
  let hub = BoardEventHub(capacity=8, client_queue_depth=2)
  for _ in 0..<5 {
    let _ = hub_tick(hub)
  }
  let client = hub.subscribe(1L, true)
  assert_true(client.plan is Replay(_))
  assert_eq(client.initial().length(), 4)
  assert_eq(client.resync_required(), None)
  let live = hub_tick(hub)
  assert_eq(client.initial().length(), 4)
  assert_eq(client.next(), @protocol.Event(live))
  let snapshot = hub.subscribe(0L, true)
  // Zero cursor demands the authoritative snapshot; no frame is fabricated
  // and the live frames keep flowing after registration.
  assert_eq(snapshot.plan, SnapshotRequired)
  assert_eq(snapshot.initial(), [])
  let next = hub_tick(hub)
  assert_eq(snapshot.next(), @protocol.Event(next))
  hub.unsubscribe(client)
  hub.unsubscribe(snapshot)
  assert_eq(hub.subscriber_count(), 0)
}

///|
async test "depth two overflow is explicit terminal and independent" {
  let hub = BoardEventHub(client_queue_depth=2)
  let slow = hub.subscribe(0L, true)
  let fast = hub.subscribe(0L, true)
  for _ in 0..<3 {
    let event = hub_tick(hub)
    assert_eq(fast.next(), @protocol.Event(event))
  }
  let expected = @protocol.ResyncRequired(
    reason="client_queue_overflow",
    current_seq=3L,
  )
  assert_eq(slow.resync_required(), Some(expected))
  assert_eq(slow.next(), expected)
  let event = hub_tick(hub)
  assert_eq(fast.next(), @protocol.Event(event))
  assert_eq(fast.resync_required(), None)
  assert_eq(
    slow.next(),
    @protocol.ResyncRequired(reason="client_queue_overflow", current_seq=4L),
  )
  hub.unsubscribe(slow)
  hub.unsubscribe(slow)
  assert_eq(hub.subscriber_count(), 1)
  hub.unsubscribe(fast)
  assert_eq(hub.subscriber_count(), 0)
  assert_true(fast.closed)
  let closed = fast.next() catch { _ => return }
  let _ = closed
  fail("closed mailbox must not deliver events")
}

///|
async test "overflow before sender sends resync instead of initial or queued frames" {
  let hub = BoardEventHub(client_queue_depth=2)
  let _ = hub_tick(hub)
  let client = hub.subscribe(0L, true)
  defer hub.unsubscribe(client)
  for _ in 0..<3 {
    let _ = hub_tick(hub)
  }
  let sent : Array[@protocol.BoardServerFrame] = []
  @async.with_timeout(1000, () => {
    board_send_subscription(client, frame => sent.push(frame))
  })
  assert_eq(sent, [
    @protocol.ResyncRequired(reason="client_queue_overflow", current_seq=4L),
  ])
}

///|
async test "overflow cancels and joins a blocked bootstrap writer" {
  let hub = BoardEventHub(client_queue_depth=2)
  let _ = hub_tick(hub)
  let client = hub.subscribe(0L, true)
  defer hub.unsubscribe(client)
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
        board_send_subscription(client, _frame => {
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
        let _ = hub_tick(hub)
      }
      sender.wait()
      assert_true(exited)
      assert_eq(sends, 1)
    })
  })
}

///|
async test "cancelling sender joins blocked writer and unsubscribes" {
  let hub = BoardEventHub(client_queue_depth=2)
  let entered : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
  let blocked : @async.Queue[Unit] = @async.Queue(kind=Blocking(1))
  let mut exited = false
  @async.with_timeout(1000, () => {
    @async.with_task_group(group => {
      let sender = group.spawn(() => {
        let client = hub.subscribe(0L, true)
        defer hub.unsubscribe(client)
        let _ = hub_tick(hub)
        board_send_subscription(client, _frame => {
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
      assert_eq(hub.subscriber_count(), 0)
    })
  })
}
