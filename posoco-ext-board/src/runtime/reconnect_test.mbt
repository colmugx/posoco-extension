///|
test "subscription bootstrap and bounded overflow public API" {
  let hub = @runtime.BoardEventHub(capacity=4, client_queue_depth=2)
  let first = hub.publish(board_revision=0L, kind="run.started", payload={})
  let client = hub.subscribe(first.seq)
  assert_eq(client.initial().length(), 0)
  assert_eq(hub.subscriber_count(), 1)
  for _ in 0..<3 {
    let _ = hub.publish(board_revision=0L, kind="assistant.delta", payload={
      "text": "safe",
    })
  }
  assert_true(client.resync_required() is Some(_))
  hub.unsubscribe(client)
  assert_eq(hub.subscriber_count(), 0)
  // A zero cursor with retained events demands the authoritative snapshot
  // plan; the hub itself never fabricates one.
  let reconnect = hub.subscribe(0L)
  assert_true(reconnect.plan is @runtime.SnapshotRequired)
  assert_eq(reconnect.initial().length(), 0)
  assert_true(reconnect.resync_required() is None)
  hub.unsubscribe(reconnect)
}
