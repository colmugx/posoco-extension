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
/// Virtual clock for monitor tests: `now_ms` reads virtual time and the
/// injected sleep parks on a condition variable until `advance` moves
/// virtual time past the deadline, so timer waits cost zero real time. A
/// real `with_timeout` still bounds each driver loop so a failing assertion
/// cannot hang the test.
priv struct VClock {
  mut now_ms : Int64
  mut stop_requested : Bool
  cv : @cond_var.Cond
}

///|
fn vclock() -> VClock {
  { now_ms: 0L, stop_requested: false, cv: @cond_var.Cond::Cond() }
}

///|
/// Wake every parked sleeper and make future sleeps return immediately, so
/// the monitor exits deterministically on teardown (otherwise a parked
/// monitor with no real timer anywhere trips the runtime deadlock
/// detector).
fn VClock::request_stop(self : VClock) -> Unit {
  self.stop_requested = true
  self.cv.broadcast()
}

///|
fn VClock::advance(self : VClock, ms : Int64) -> Unit {
  self.now_ms = self.now_ms + ms
  self.cv.broadcast()
}

///|
async fn VClock::sleep_ms(self : VClock, ms : Int) -> Unit {
  let deadline = self.now_ms + ms.to_int64()
  while self.now_ms < deadline && !self.stop_requested {
    self.cv.wait() catch {
      _ => return
    }
  }
}

///|
async test "monitor auto-resumes the interrupted turn once quota resets" {
  let clock = vclock()
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Fail(
      @posoco.ModelError::RateLimited(@posoco.RateLimitInfo::{
        message: "Usage limit reached for the past 5 hours. Resets soon.",
        reset_at_ms: Some(40000L),
        provider_code: Some("1308"),
      }),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("resumed")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let guard_ext = RateLimitGuard(
    margin_ms=0,
    poll_interval_ms=5,
    now_ms=fn() { clock.now_ms },
    sleep_ms=async fn(ms : Int) { clock.sleep_ms(ms) },
  )
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
    let drove : Result[Unit, Error] = Ok(
      @async.with_timeout(2000, () => {
        while model.call_count() < 2 {
          clock.advance(10000L)
          @async.pause()
          @async.sleep(1)
        }
      }),
    ) catch {
      error => Err(error)
    }
    guard_ext.stop()
    clock.request_stop()
    @async.pause()
    assert_true(drove is Ok(_))
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

///|
/// ModelPort fake whose chat sleeps real milliseconds before responding;
/// starts and completions are counted separately so a test can prove
/// another resume ran while a turn was still in flight.
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
  @async.sleep(self.delay_ms) catch {
    _ => ()
  }
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
  raise @posoco.ModelError::ResponseParse(
    "DelayedModel does not implement compact",
  )
}

///|
pub impl @posoco.ModelPort for DelayedModel with fn provider_config(
  _self : DelayedModel,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
async test "two due sessions both resume; turns serialize on one agent" {
  let clock = vclock()
  let model : DelayedModel = { delay_ms: 150, started: 0, finished: 0 }
  let guard_ext = RateLimitGuard(
    margin_ms=0,
    poll_interval_ms=5,
    now_ms=fn() { clock.now_ms },
    sleep_ms=async fn(ms : Int) { clock.sleep_ms(ms) },
  )
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[
        @posoco.RecordingSessionStore::RecordingSessionStore(),
      ]),
      @posoco.tk_ext(id="guard", hooks=[guard_ext], observers=[guard_ext]),
    ],
    config=@posoco.tk_config(),
  )
  guard_ext.bind(agent)
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(40000L)))
  hook.on_post_event_at(Some(test_scope("s2")), quota_failure(Some(40000L)))
  @async.with_task_group(group => {
    guard_ext.spawn_monitor(group)
    let first : Result[Unit, Error] = Ok(
      @async.with_timeout(2000, () => {
        while model.started < 1 {
          clock.advance(10000L)
          @async.pause()
          @async.sleep(1)
        }
      }),
    ) catch {
      error => Err(error)
    }
    assert_true(first is Ok(_))
    // The first resume is mid-turn (model sleeping); the second resume task
    // exists but its turn is queued on the agent's single execution loop.
    assert_eq(model.started, 1)
    assert_eq(model.finished, 0)
    let settled : Result[Unit, Error] = Ok(
      @async.with_timeout(2000, () => {
        while model.finished < 2 {
          @async.sleep(5)
        }
      }),
    ) catch {
      error => Err(error)
    }
    guard_ext.stop()
    clock.request_stop()
    assert_true(settled is Ok(_))
    assert_eq(model.started, 2)
    assert_eq(model.finished, 2)
    assert_eq(guard_ext.pending_snapshots().length(), 0)
  })
}

///|
async test "failing resume is rescheduled and does not kill the monitor" {
  let clock = vclock()
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Fail(
      @posoco.ModelError::RateLimited(@posoco.RateLimitInfo::{
        message: "Usage limit reached.",
        reset_at_ms: Some(30000L),
        provider_code: None,
      }),
    ),
    @posoco.ScriptedModelStep::Fail(
      @posoco.ModelError::Transport("resume exploded"),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let guard_ext = RateLimitGuard(
    margin_ms=0,
    poll_interval_ms=5,
    now_ms=fn() { clock.now_ms },
    sleep_ms=async fn(ms : Int) { clock.sleep_ms(ms) },
  )
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[
        @posoco.RecordingSessionStore::RecordingSessionStore(),
      ]),
      @posoco.tk_ext(id="guard", hooks=[guard_ext], observers=[guard_ext]),
    ],
    config=@posoco.tk_config(),
  )
  guard_ext.bind(agent)
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(30000L)))
  @async.with_task_group(group => {
    guard_ext.spawn_monitor(group)
    // The retried turn first hits a fresh quota verdict (re-recorded from
    // inside the resume task), then a Transport failure (short reschedule),
    // then succeeds — proving neither failure kills the monitor.
    let drove : Result[Unit, Error] = Ok(
      @async.with_timeout(2000, () => {
        while model.call_count() < 3 {
          clock.advance(1000L)
          @async.pause()
          @async.sleep(1)
        }
      }),
    ) catch {
      error => Err(error)
    }
    guard_ext.stop()
    clock.request_stop()
    @async.pause()
    assert_true(drove is Ok(_))
    assert_eq(model.call_count(), 3)
    assert_eq(guard_ext.pending_snapshots().length(), 0)
  })
}
