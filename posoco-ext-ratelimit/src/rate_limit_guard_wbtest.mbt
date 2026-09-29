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
      reason="You've reached your 5-hour usage limit.",
      reset_at_ms~,
      provider_code=Some("429"),
    ),
  )
}

///|
test "recovery policy preserves provider deadline and probe backoff" {
  let policy : RecoveryPolicy = {
    margin_ms: 15000L,
    max_attempts: 3,
    probe_interval_ms: 600000L,
    max_probe_interval_ms: 3600000L,
  }
  assert_true(policy.schedule(Some(50000L), 1, 1000L) is Scheduled(65000L))
  assert_true(policy.schedule(None, 1, 1000L) is Scheduled(601000L))
  assert_true(policy.schedule(None, 2, 1000L) is Scheduled(1201000L))
  assert_true(policy.schedule(None, 4, 1000L) is Exhausted)
}

///|
test "5h status naming remains conservative" {
  assert_eq(
    five_hour_label("You've reached your 5-hour usage limit"),
    Some("5h"),
  )
  assert_eq(five_hour_label("current 5-hour window ends at noon"), Some("5h"))
  assert_eq(five_hour_label("limit resets in 5 hours"), None)
  assert_eq(five_hour_label("weekly limit reached"), None)
}

///|
test "reset formatting remains UTC and deterministic" {
  assert_eq(fmt_reset_at(0L), "1970-01-01T00:00:00Z")
  assert_eq(fmt_reset_at(86400000L), "1970-01-02T00:00:00Z")
  assert_eq(fmt_reset_at(951782400000L), "2000-02-29T00:00:00Z")
}

///|
async test "hook events mutate only actor-owned recovery state" {
  let guard_ext = RateLimitGuard(
    margin_ms=0,
    now_ms=fn() { 49000L },
    sleep_ms=async fn(_ms : Int) { @async.sleep(60000) },
  )
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("unused")),
  ])
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[
        @posoco.RecordingSessionStore::RecordingSessionStore(),
      ]),
      guard_ext,
    ],
    config=@posoco.tk_config(),
  )
  @async.with_task_group(group => {
    guard_ext.start(group~, agent~)
    let hook : &@posoco.PipelineHook = guard_ext
    hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(50000L)))
    let pending = guard_ext.snapshot()
    assert_eq(pending.length(), 1)
    assert_eq(pending[0].session_id, "s1")
    assert_eq(pending[0].encountered_at_ms, 49000L)
    assert_eq(pending[0].resume_at_ms, 50000L)
    assert_eq(pending[0].attempts, 1)
    guard_ext.shutdown()
  })
}

///|
async test "cancel_pending invalidates actor schedule" {
  let guard_ext = RateLimitGuard(
    now_ms=fn() { 1000L },
    sleep_ms=async fn(_ms : Int) { @async.sleep(60000) },
  )
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("unused")),
  ])
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[
        @posoco.RecordingSessionStore::RecordingSessionStore(),
      ]),
      guard_ext,
    ],
    config=@posoco.tk_config(),
  )
  @async.with_task_group(group => {
    guard_ext.start(group~, agent~)
    let hook : &@posoco.PipelineHook = guard_ext
    hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(50000L)))
    assert_eq(guard_ext.snapshot().length(), 1)
    guard_ext.cancel_pending()
    // snapshot() is an actor ask and therefore also serves as the FIFO barrier.
    assert_eq(guard_ext.snapshot().length(), 0)
    guard_ext.shutdown()
  })
}

///|
async test "429 failed turn auto-resumes through supervised event timer" {
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Fail(
      @posoco.ModelError::RateLimited(@posoco.RateLimitInfo::{
        message: "quota exhausted",
        reset_at_ms: Some(0L),
        provider_code: Some("429"),
      }),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("resumed")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let guard_ext = RateLimitGuard(
    margin_ms=0,
    now_ms=fn() { 0L },
  )
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store]),
      guard_ext,
    ],
    config=@posoco.tk_config(),
  )
  @async.with_task_group(group => {
    guard_ext.start(group~, agent~)
    let first : Result[@posoco.TurnResult, @posoco.AgentError] = Ok(
      agent.run_turn(@posoco.tk_user_msg("task"), "s1"),
    ) catch {
      error => Err(error)
    }
    assert_true(first is Err(_))
    let resumed : Result[Unit, Error] = Ok(
      @async.with_timeout(2000, () => {
        while model.call_count() < 2 {
          @async.sleep(1)
        }
      }),
    ) catch {
      error => Err(error)
    }
    assert_true(resumed is Ok(_))
    assert_eq(guard_ext.snapshot().length(), 0)
    let session = store.store["s1"]
    assert_eq(session.messages.length(), 2)
    assert_true(session.messages[0] is UserMessage(content=[Text("task"), ..]))
    assert_true(
      session.messages[1] is AssistantMessage(content=[Text("resumed"), ..], ..),
    )
    guard_ext.shutdown()
  })
}

///|
/// A slow model lets the test observe the single-inflight invariant without
/// relying on a Semaphore implementation detail.
struct DelayedModel {
  delay_ms : Int
  mut started : Int
  mut finished : Int
}

///|
pub impl @posoco.ModelPort for DelayedModel with fn chat(
  self : DelayedModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.started = self.started + 1
  @async.sleep(self.delay_ms)
  self.finished = self.finished + 1
  @posoco.tk_stop_response("done")
}

///|
pub impl @posoco.ModelPort for DelayedModel with fn compact(
  _self : DelayedModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("DelayedModel does not implement compact")
}

///|
pub impl @posoco.ModelPort for DelayedModel with fn provider_config(
  _self : DelayedModel,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
pub extend DelayedModel with @posoco.ModelPort::{provider_config, chat, compact}

///|
async test "simultaneous due sessions serialize resume execution" {
  let now = Ref(1000L)
  let model : DelayedModel = { delay_ms: 100, started: 0, finished: 0, }
  let guard_ext = RateLimitGuard(
    margin_ms=0,
    now_ms=fn() { now.val },
    sleep_ms=async fn(_ms : Int) { @async.sleep(60000) },
  )
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[
        @posoco.RecordingSessionStore::RecordingSessionStore(),
      ]),
      guard_ext,
    ],
    config=@posoco.tk_config(),
  )
  @async.with_task_group(group => {
    guard_ext.start(group~, agent~)
    let hook : &@posoco.PipelineHook = guard_ext
    let observer : &@posoco.Observer = guard_ext
    for id in ["s1", "s2"] {
      hook.on_post_event_at(Some(test_scope(id)), quota_failure(Some(1000L)))
      observer.on_event_at(
        Some(test_scope(id)),
        @posoco.TurnEvent::TurnFailed("quota"),
      )
    }
    guard_ext.poll()
    let first_started : Result[Unit, Error] = Ok(
      @async.with_timeout(1000, () => {
        while model.started < 1 {
          @async.sleep(1)
        }
      }),
    ) catch {
      error => Err(error)
    }
    assert_true(first_started is Ok(_))
    assert_eq(model.started, 1)
    assert_eq(model.finished, 0)
    let both_finished : Result[Unit, Error] = Ok(
      @async.with_timeout(2000, () => {
        while model.finished < 2 {
          @async.sleep(1)
        }
      }),
    ) catch {
      error => Err(error)
    }
    assert_true(both_finished is Ok(_))
    assert_eq(model.started, 2)
    assert_eq(model.finished, 2)
    guard_ext.shutdown()
  })
}
