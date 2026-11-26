///|
test "snapshot_turn_event passes SessionRewound through unchanged" {
  let event : @types.TurnEvent = SessionRewound(
    session_id="s1",
    messages_before=4,
    messages_after=2,
  )
  guard @testkit.snapshot_turn_event(event)
    is SessionRewound(session_id="s1", ..) else {
    fail("expected the scalar-only variant to pass through")
  }
}
