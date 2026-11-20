///|
fn session_frame(
  session_id : String,
  kind : String,
  epoch : String,
  cursor : Int32,
  advance : Bool,
  busy : Bool,
) -> Json {
  Json::object({
    "session_id": Json::string(session_id),
    "type": Json::string(kind),
    "runtime_epoch": Json::string(epoch),
    "cursor": Json::number(cursor.to_double()),
    "high_water_cursor": Json::number(cursor.to_double()),
    "cursor_advance": Json::boolean(advance),
    "busy": Json::boolean(busy),
  })
}

///|
test "Go to Go: joining a working Session gets working from snapshot" {
  let b = SessionReplica::new("s-1")
  let frame = session_frame(
    "s-1", "session.snapshot", "epoch-a", 7, false, true,
  )
  assert_eq(b.apply(frame), Applied)
  assert_true(b.attached())
  assert_true(b.working())
  assert_eq(b.cursor(), 7)
}

///|
test "Go to JS and JS to Go: host-neutral events carry contiguous deltas" {
  let b = SessionReplica::new("s-1")
  assert_eq(
    b.apply(
      session_frame("s-1", "session.snapshot", "epoch-a", 4, false, false),
    ),
    Applied,
  )
  assert_eq(
    b.apply(session_frame("s-1", "turn.accepted", "epoch-a", 5, true, false)),
    Applied,
  )
  assert_true(b.working())
  assert_eq(
    b.apply(
      session_frame("s-1", "assistant.text_delta", "epoch-a", 6, true, false),
    ),
    Applied,
  )
  assert_eq(b.cursor(), 6)
  assert_true(b.working())
  assert_eq(
    b.apply(session_frame("s-1", "turn.completed", "epoch-a", 7, true, false)),
    Applied,
  )
  assert_false(b.working())
}

///|
test "per-Surface cursors isolate observers and reject gaps" {
  let a = SessionReplica::new("s-a")
  let b = SessionReplica::new("s-b")
  assert_eq(
    a.apply(session_frame("s-a", "session.snapshot", "epoch", 11, false, true)),
    Applied,
  )
  assert_eq(
    b.apply(session_frame("s-b", "session.snapshot", "epoch", 2, false, false)),
    Applied,
  )
  assert_eq(
    b.apply(session_frame("s-a", "turn.accepted", "epoch", 12, true, false)),
    Ignored,
  )
  assert_eq(b.cursor(), 2)
  assert_eq(
    a.apply(
      session_frame("s-a", "assistant.text_delta", "epoch", 13, true, false),
    ),
    NeedsSnapshot("session cursor gap"),
  )
  assert_false(a.attached())
  assert_eq(
    a.apply(session_frame("s-a", "turn.completed", "epoch", 14, true, false)),
    NeedsSnapshot("event before session snapshot"),
  )
}

///|
test "epoch replacement always requires a new snapshot" {
  let b = SessionReplica::new("s-1")
  ignore(
    b.apply(session_frame("s-1", "session.snapshot", "epoch-a", 9, false, true)),
  )
  assert_eq(
    b.apply(session_frame("s-1", "turn.completed", "epoch-b", 10, true, false)),
    NeedsSnapshot("runtime epoch changed"),
  )
  assert_false(b.attached())
  assert_eq(
    b.apply(
      session_frame("s-1", "session.snapshot", "epoch-b", 1, false, false),
    ),
    Applied,
  )
  assert_false(b.working())
  assert_eq(b.cursor(), 1)
}

///|
test "unicast state does not invent broadcast cursor advancement" {
  let b = SessionReplica::new("s-1")
  ignore(
    b.apply(session_frame("s-1", "session.snapshot", "epoch", 3, false, false)),
  )
  assert_eq(
    b.apply(session_frame("s-1", "session.notice", "epoch", 3, false, false)),
    Applied,
  )
  assert_eq(b.cursor(), 3)
  assert_eq(
    b.apply(session_frame("s-1", "turn.accepted", "epoch", 4, true, false)),
    Applied,
  )
}
