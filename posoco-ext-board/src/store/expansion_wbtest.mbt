///|
test "recovery preserves expansion identities without rehashing edited tasks" {
  let snapshot = x_proposal().next_state.snapshot()
  let recovery = recover_snapshot(snapshot, at_ms=100L).unwrap()
  assert_eq(recovery.snapshot, snapshot)
  assert_eq(recovery.events, [])
}

///|
test "event codec rejects partial mapping changed content and malformed digest" {
  let proposal = x_proposal()
  let base = match event_json(proposal.events[0]) {
    Json::Object(f) => f
    _ => abort("object")
  }
  for
    pair in [
      ("mapping", Json::array([])),
      ("workflow_id", Json::null()),
      ("content_digest", Json::string("sha256:bad")),
      ("workflow_id", Json::string("different")),
      ("tasks", Json::array([])),
    ] {
    let f = base.copy()
    f[pair.0] = pair.1
    assert_true(
      decode_event(Json::object(f).stringify()) is Err(InvalidData(_)),
    )
  }
  let missing = base.copy()
  let _ = missing.remove("tasks")
  assert_true(
    decode_event(Json::object(missing).stringify()) is Err(InvalidData(_)),
  )
}
