///|
/// Live smoke test, env-gated on ZCODE_EXT_LIVE=1 (CI and default runs skip
/// it): one real zcode delegation against the local app-server — roughly one
/// GLM call at ~30k input tokens. Run after upgrading zcode; it is the main
/// wire-contract regression defense.

///|
async test "merge_event_params_unwraps_nested_payload" {
  let nested = @json.parse(
    (
      #|{"sessionId": "sess_1", "type": "model.streaming", "payload": {"kind": "text_delta", "delta": "pong", "done": false}}
    ),
  )
  match
    zcode_reduce_notification("session/event", zcode_merge_event_params(nested)) {
    Some(TextDelta(delta)) => assert_eq(delta, "pong")
    _ => fail("expected TextDelta from nested payload")
  }
  let flat = @json.parse(
    (
      #|{"type": "model.streaming", "kind": "text_delta", "delta": "pong"}
    ),
  )
  match
    zcode_reduce_notification("session/event", zcode_merge_event_params(flat)) {
    Some(TextDelta(delta)) => assert_eq(delta, "pong")
    _ => fail("expected TextDelta from flat params")
  }
  let params_type_wins = @json.parse(
    (
      #|{"type": "turn.completed", "payload": {"type": "model.streaming", "response": "pong"}}
    ),
  )
  match
    zcode_reduce_notification(
      "session/event",
      zcode_merge_event_params(params_type_wins),
    ) {
    Some(TurnCompleted(response~, ..)) => assert_eq(response, "pong")
    _ => fail("expected params-level type to win over payload")
  }
  let no_payload = @json.parse(
    (
      #|{"type": "turn.started"}
    ),
  )
  assert_true(
    zcode_reduce_notification(
      "session/event",
      zcode_merge_event_params(no_payload),
    )
    is Some(TurnStarted),
  )
}

///|
async test "live_pong_delegation" {
  // ZCODE_EXT_LIVE=1 gate FIRST: nothing below — no env reads, no ~/.zcode
  // stat, no creds access — runs unless the live probe is opted in.
  let enabled = match @env.get_env_var("ZCODE_EXT_LIVE") {
    Some("1") => true
    _ => false
  }
  if !enabled {
    // skip: ZCODE_EXT_LIVE=1 not set
    assert_true(true)
    return
  }
  let creds = zcode_creds_path(config=zcode_config(), env=key => {
    @env.get_env_var(key)
  })
  let creds_ready = @fs.exists(creds) catch { _ => false }
  if !creds_ready {
    // skip: no local v2 credentials
    assert_true(true)
    return
  }
  let cwd = @fs.tmpdir(prefix="posoco-zcode-live") catch { _ => "/tmp" }
  let result = zcode_run_task(
    config=zcode_config(),
    task="Reply with exactly the single word pong and do nothing else.",
    cwd~,
    session_id=None,
    mode="edit",
  )
  println(
    "[live] stop=\{result.stop_reason} session=\{result.session_id} text=\{result.final_text}",
  )
  assert_eq(result.stop_reason, "success")
  assert_true(result.final_text.contains("pong"))
  assert_true(result.session_id != "")
}
