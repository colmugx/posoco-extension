///|
fn hub_tick(hub : BoardEventHub) -> @protocol.BoardWireEvent {
  hub.publish(board_revision=0L, kind="assistant.delta", payload={
    "text": "[redacted]",
  })
}

///|
fn assert_snapshot(
  client : BoardSubscription,
  hub : BoardEventHub,
) -> Unit raise {
  let frames = client.initial()
  assert_eq(frames.length(), 1)
  guard frames[0] is Snapshot(snapshot) else { fail("expected snapshot") }
  assert_eq(snapshot.last_seq, hub.current_seq())
  assert_eq(snapshot.board_revision, 0L)
  assert_eq(snapshot.protocol_version, @protocol.protocol_version())
  assert_eq(snapshot.payload, {
    "events": hub.history().map(event => event.to_json()),
  })
}

///|
test "replay boundaries empty current zero covered gap and future" {
  let hub = BoardEventHub(capacity=2)
  let empty = hub.subscribe(0L)
  assert_eq(empty.initial(), [])
  hub.unsubscribe(empty)
  let future_empty = hub.subscribe(1L)
  assert_snapshot(future_empty, hub)
  hub.unsubscribe(future_empty)
  let first = hub_tick(hub)
  let zero = hub.subscribe(0L)
  assert_snapshot(zero, hub)
  hub.unsubscribe(zero)
  let second = hub_tick(hub)
  let third = hub_tick(hub)
  let covered = hub.subscribe(first.seq)
  assert_eq(covered.initial(), [@protocol.Event(second), @protocol.Event(third)])
  hub.unsubscribe(covered)
  let current = hub.subscribe(3L)
  assert_eq(current.initial(), [])
  hub.unsubscribe(current)
  let fourth = hub_tick(hub)
  assert_eq(fourth.seq, 4L)
  for cursor in [0L, 1L, 5L] {
    let reset = hub.subscribe(cursor)
    assert_snapshot(reset, hub)
    hub.unsubscribe(reset)
  }
  assert_eq(hub.subscriber_count(), 0)
}

///|
async test "atomic bootstrap then live never fills mailbox with replay" {
  let hub = BoardEventHub(capacity=8, client_queue_depth=2)
  for _ in 0..<5 {
    let _ = hub_tick(hub)
  }
  let client = hub.subscribe(1L)
  assert_eq(client.initial().length(), 4)
  assert_eq(client.resync_required(), None)
  let live = hub_tick(hub)
  assert_eq(client.initial().length(), 4)
  assert_eq(client.next(), @protocol.Event(live))
  let snapshot = hub.subscribe(0L)
  let next = hub_tick(hub)
  guard snapshot.initial()[0] is Snapshot(frame) else {
    fail("expected snapshot")
  }
  assert_eq(frame.last_seq, 6L)
  assert_eq(snapshot.next(), @protocol.Event(next))
  hub.unsubscribe(client)
  hub.unsubscribe(snapshot)
  assert_eq(hub.subscriber_count(), 0)
}

///|
async test "depth two overflow is explicit terminal and independent" {
  let hub = BoardEventHub(client_queue_depth=2)
  let slow = hub.subscribe(0L)
  let fast = hub.subscribe(0L)
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
  let client = hub.subscribe(0L)
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
  let client = hub.subscribe(0L)
  defer hub.unsubscribe(client)
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
        let client = hub.subscribe(0L)
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
