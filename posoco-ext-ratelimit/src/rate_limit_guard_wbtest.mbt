///|
fn test_scope(session_id : String) -> @posoco.EventScope {
  {
    session_id: @posoco.SessionId::unchecked(session_id),
    run_id: @posoco.RunId::unchecked("run"),
    turn_id: @posoco.TurnId::unchecked("turn"),
  }
}

///|
fn quota_failure(reset_at_ms : Int64?) -> @posoco.HookStage {
  @posoco.HookStage::ModelFailed(
    failure=@posoco.ModelFailure::RateLimited(
      reason="HTTP 429: quota",
      reset_at_ms~,
      provider_code=Some("1308"),
    ),
  )
}

///|
async test "rate-limited model failure schedules a resume" {
  let guard_ext = RateLimitGuard(margin_ms=1000)
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(50000L)))
  let pending = guard_ext.pending_snapshots()
  assert_eq(pending.length(), 1)
  assert_eq(pending[0].session_id, "s1")
  assert_eq(pending[0].resume_at_ms, 51000L)
  assert_eq(pending[0].attempts, 1)
  assert_eq(pending[0].provider_code, Some("1308"))
}

///|
async test "verdict without reset time schedules a probe by default" {
  let guard_ext = RateLimitGuard(probe_interval_ms=600000, now_ms=fn() { 1000L })
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(None))
  let pending = guard_ext.pending_snapshots()
  assert_eq(pending.length(), 1)
  assert_eq(pending[0].resume_at_ms, 601000L)
  // Second unschedulable verdict backs off: 600s << (attempts-1) = 1200s.
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(None))
  assert_eq(guard_ext.pending_snapshots()[0].resume_at_ms, 1201000L)
}

///|
async test "verdict without reset time is ignored when probing is disabled" {
  let guard_ext = RateLimitGuard(probe_interval_ms=0)
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(None))
  assert_eq(guard_ext.pending_snapshots().length(), 0)
}

///|
async test "attempts are capped per session" {
  let guard_ext = RateLimitGuard(max_attempts=2)
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(50000L)))
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(60000L)))
  assert_eq(guard_ext.pending_snapshots().length(), 1)
  assert_eq(guard_ext.pending_snapshots()[0].attempts, 2)
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(70000L)))
  assert_eq(guard_ext.pending_snapshots().length(), 0)
}

///|
async test "TurnCompleted clears the session's schedule and attempt count" {
  let guard_ext = RateLimitGuard()
  let hook : &@posoco.PipelineHook = guard_ext
  let observer : &@posoco.Observer = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(50000L)))
  observer.on_event_at(Some(test_scope("s1")), @posoco.TurnEvent::TurnCompleted)
  assert_eq(guard_ext.pending_snapshots().length(), 0)
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(50000L)))
  assert_eq(guard_ext.pending_snapshots()[0].attempts, 1)
}

///|
async test "monitor auto-resumes the interrupted turn once quota resets" {
  let fail_at = @async.now() + 40L
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Fail(
      @posoco.ModelError::RateLimited(@posoco.RateLimitInfo::{
        status: 429,
        message: "Usage limit reached for the past 5 hours. Resets soon.",
        reset_at_ms: Some(fail_at),
        provider_code: Some("1308"),
      }),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("resumed")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let guard_ext = RateLimitGuard(margin_ms=0, poll_interval_ms=5)
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store]),
      @posoco.tk_ext(id="guard", hooks=[guard_ext], observers=[guard_ext]),
    ],
    config=@posoco.tk_config(),
  )
  guard_ext.bind(agent)
  @async.with_task_group(group => {
    guard_ext.spawn_monitor(group)
    let first : Result[@posoco.TurnResult, @posoco.AgentError] = Ok(
      agent.run_turn(@posoco.tk_user_msg("task"), "s1"),
    ) catch {
      error => Err(error)
    }
    assert_true(first is Err(_))
    let deadline = @async.now() + 3000L
    let mut resumed = false
    while @async.now() < deadline {
      if model.call_count() >= 2 {
        resumed = true
        break
      }
      @async.sleep(5)
    }
    guard_ext.stop()
    assert_true(resumed)
    let session = store.store["s1"]
    assert_eq(session.messages.length(), 3)
    assert_true(session.messages[0] is UserMessage(content=[Text("task"), ..]))
    assert_true(session.messages[1] is UserMessage(..))
    assert_true(
      session.messages[2] is AssistantMessage(content=[Text("resumed"), ..], ..),
    )
    assert_eq(model.call_count(), 2)
    assert_eq(guard_ext.pending_snapshots().length(), 0)
  })
}
