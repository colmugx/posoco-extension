///|
test "event hub mints monotonic seq" {
  let hub = BoardEventHub::BoardEventHub(capacity=8)
  let first = hub.publish(
    board_revision=0L,
    kind="turn.started",
    payload=Json::null(),
  )
  let second = hub.publish(
    board_revision=0L,
    kind="assistant.delta",
    payload=Json::string("x"),
  )
  assert_eq(first.seq, 1L)
  assert_eq(second.seq, 2L)
  assert_eq(hub.current_seq(), 2L)
}

///|
test "event seq advances independently from board revision" {
  let hub = BoardEventHub::BoardEventHub(capacity=8)
  let a = hub.publish(
    board_revision=7L,
    kind="assistant.delta",
    payload=Json::string("a"),
  )
  let b = hub.publish(
    board_revision=7L,
    kind="assistant.delta",
    payload=Json::string("b"),
  )
  let c = hub.publish(
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
  let hub = BoardEventHub::BoardEventHub(capacity=2)
  for i in 0..<3 {
    let _ = hub.publish(
      board_revision=0L,
      kind="tick",
      payload=Json::number(i.to_double()),
    )
  }
  let history = hub.history()
  assert_eq(history.length(), 2)
  assert_eq(history[0].seq, 2L)
  assert_eq(history[1].seq, 3L)
  let replay = hub.history_since(2L)
  assert_eq(replay.length(), 1)
  assert_eq(replay[0].seq, 3L)
}
