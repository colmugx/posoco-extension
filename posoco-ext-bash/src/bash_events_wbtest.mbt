///|
/// Whitebox tests for the advisory session notices (`bash_events.mbt`): each
/// `bash.session.*` lifecycle fact is a typed `BashSessionNotice` on the
/// `@events` channel, published through an owner-bound capability.

///|
fn notice_test_session() -> ShellSession {
  {
    id: "s_notice",
    effect_id: @kernel.EffectId::{ value: 7, },
    started_at_ms: @async.now(),
    last_output_at_ms: @async.now(),
    ended_at_ms: None,
    status: "completed",
    output: "hello",
    base_cursor: 0L,
    next_cursor: 5L,
    outcome: None,
    exit_code: Some(0),
    worker: None,
    kill_requested: false,
  }
}

///|
test "session notices publish a typed BashSessionNotice on the events channel" {
  let system = @posoco.EventSystem()
  @devkit.events_system_register(system)
  let envelopes : Array[@posoco.EventEnvelope] = []
  match system.subscribe(fn(envelope) { envelopes.push(envelope) }) {
    Ok(_) => ()
    Err(_) => fail("subscribe on a fresh EventSystem failed")
  }
  let tools = ShellTools::ShellTools()
  let session = notice_test_session()
  tools.emit_session(session, BASH_SESSION_FINISHED)
  assert_eq(envelopes.length(), 1)
  // The publisher identity rides the capability, not the payload.
  assert_eq(envelopes[0].namespace_of(), @events.Extension("posoco_ext_bash"))
  match envelopes[0].event {
    BashSessionNotice(payload) => {
      assert_eq(payload.kind, BASH_SESSION_FINISHED)
      // The snapshot object is the one `ShellSession::snapshot` produces, so
      // a host reading it sees the documented keys and values.
      let snapshot = payload.snapshot
      guard snapshot is Json::Object(fields) else {
        fail("a session notice must carry an object snapshot")
      }
      assert_eq(fields.get("session_id"), Some(Json::string("s_notice")))
      assert_eq(fields.get("status"), Some(Json::string("completed")))
      assert_eq(fields.get("cursor"), Some(Json::number(5.0)))
      assert_eq(fields.get("exit_code"), Some(Json::number(0.0)))
    }
    _ => fail("expected a BashSessionNotice event")
  }
}

///|
test "a missing or closed system makes the notice a silent no-op" {
  // No system registered yet: the accounting-free emission path never raises.
  let tools = ShellTools::ShellTools()
  tools.emit_session(notice_test_session(), BASH_SESSION_STALL)
  let system = @posoco.EventSystem()
  @devkit.events_system_register(system)
  let envelopes : Array[@posoco.EventEnvelope] = []
  match system.subscribe(fn(envelope) { envelopes.push(envelope) }) {
    Ok(_) => ()
    Err(_) => fail("subscribe on a fresh EventSystem failed")
  }
  assert_true(system.close() is Ok(_))
  tools.emit_session(notice_test_session(), BASH_SESSION_STARTED)
  assert_eq(envelopes.length(), 0)
}
