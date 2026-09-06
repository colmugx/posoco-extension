///|
fn test_scope(session_id : String) -> @posoco.EventScope {
  {
    session_id: @posoco.SessionId::unchecked(session_id),
    run_id: @posoco.RunId::unchecked("run"),
    turn_id: @posoco.TurnId::unchecked("turn"),
  }
}

///|
fn quota_failure_with(
  reason : String,
  reset_at_ms : Int64?,
) -> @posoco.HookStage {
  @posoco.HookStage::ModelFailed(
    failure=@posoco.ModelFailure::RateLimited(
      reason~,
      reset_at_ms~,
      provider_code=Some("1308"),
    ),
  )
}

///|
fn quota_failure(reset_at_ms : Int64?) -> @posoco.HookStage {
  quota_failure_with("HTTP 429: quota", reset_at_ms)
}

///|
test "5h window naming needs the window keyword" {
  assert_eq(
    five_hour_label("You've reached your 5-hour usage limit"),
    Some("5h"),
  )
  assert_eq(five_hour_label("current 5-hour window ends at noon"), Some("5h"))
  assert_eq(five_hour_label("limit resets in 5 hours"), None)
  assert_eq(five_hour_label("weekly limit reached"), None)
  assert_eq(five_hour_label("the 125-hour window"), None)
}

///|
async test "rate-limited model failure schedules a resume" {
  let traces : Array[String] = []
  let guard_ext = RateLimitGuard(now_ms=fn() { 49000L }, trace=fn(
    line : String,
  ) {
    traces.push(line)
  })
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(50000L)))
  let pending = guard_ext.pending_snapshots()
  assert_eq(pending.length(), 1)
  assert_eq(pending[0].session_id, "s1")
  assert_eq(pending[0].encountered_at_ms, 49000L)
  assert_eq(pending[0].reset_at_ms, Some(50000L))
  // The default deadline is the provider deadline exactly: no hidden 15s.
  assert_eq(pending[0].resume_at_ms, 50000L)
  assert_eq(pending[0].attempts, 1)
  assert_eq(pending[0].provider_code, Some("1308"))
  assert_true(traces.any(fn(line) { line.contains("encountered_at_ms=49000") }))
}

///|
async test "due recovery waits for the failed-turn boundary" {
  let guard_ext = RateLimitGuard(now_ms=fn() { 50000L })
  let hook : &@posoco.PipelineHook = guard_ext
  let observer : &@posoco.Observer = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(50000L)))
  // The hook fires before Agent persists the failed transcript.
  assert_eq(guard_ext.take_due(50000L).length(), 0)
  observer.on_event_at(
    Some(test_scope("s1")),
    @posoco.TurnEvent::TurnFailed("quota"),
  )
  assert_eq(guard_ext.take_due(50000L).length(), 1)
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
async test "cancel invalidates pending, taken, and late in-flight tickets" {
  let traces : Array[String] = []
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("must not run")),
  ])
  let guard_ext = RateLimitGuard(now_ms=fn() { 50000L }, trace=fn(
    line : String,
  ) {
    traces.push(line)
  })
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[
        @posoco.RecordingSessionStore::RecordingSessionStore(),
      ]),
    ],
    config=@posoco.tk_config(),
  )
  guard_ext.bind(agent)
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(50000L)))
  let observer : &@posoco.Observer = guard_ext
  observer.on_event_at(
    Some(test_scope("s1")),
    @posoco.TurnEvent::TurnFailed("quota"),
  )
  let taken = guard_ext.take_due(50000L)
  assert_eq(taken.length(), 1)
  let stale_generation = taken[0].generation
  guard_ext.cancel_pending()
  guard_ext.resume_entry(taken[0])
  assert_eq(model.call_count(), 0)
  // ModelFailed can arrive after cancellation from an already in-flight
  // recovery. The active old generation prevents it recreating a schedule.
  guard_ext.active_resume_generation = Some(stale_generation)
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(60000L)))
  guard_ext.active_resume_generation = None
  assert_eq(guard_ext.pending_snapshots().length(), 0)
  assert_true(traces.any(fn(line) { line.contains("ignored stale") }))
}

///|
async test "a resumed rate limit schedules only the next provider deadline" {
  let now = Ref(0L)
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Fail(
      @posoco.ModelError::RateLimited(@posoco.RateLimitInfo::{
        message: "first limit",
        reset_at_ms: Some(10000L),
        provider_code: Some("429"),
      }),
    ),
    @posoco.ScriptedModelStep::Fail(
      @posoco.ModelError::RateLimited(@posoco.RateLimitInfo::{
        message: "second limit",
        reset_at_ms: Some(20000L),
        provider_code: Some("429"),
      }),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("done")),
  ])
  let store = @posoco.RecordingSessionStore::RecordingSessionStore()
  let guard_ext = RateLimitGuard(now_ms=fn() { now.val })
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store]),
      @posoco.tk_ext(id="guard", hooks=[guard_ext], observers=[guard_ext]),
    ],
    config=@posoco.tk_config(),
  )
  guard_ext.bind(agent)
  let first = Ok(agent.run_turn(@posoco.tk_user_msg("task"), "repeat")) catch {
    error => Err(error)
  }
  assert_true(first is Err(_))
  now.val = 10000L
  guard_ext.poll()
  let second = guard_ext.pending_snapshots()
  assert_eq(second.length(), 1)
  assert_eq(second[0].encountered_at_ms, 10000L)
  assert_eq(second[0].reset_at_ms, Some(20000L))
  assert_eq(second[0].resume_at_ms, 20000L)
  now.val = 20000L
  guard_ext.poll()
  assert_eq(model.call_count(), 3)
  assert_eq(guard_ext.pending_snapshots().length(), 0)
  let persisted = store.store["repeat"]
  assert_eq(persisted.messages.length(), 2)
  assert_true(persisted.messages[0] is UserMessage(content=[Text("task"), ..]))
  assert_true(
    persisted.messages[1] is AssistantMessage(content=[Text("done"), ..], ..),
  )
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
  { now_ms: 0L, stop_requested: false, cv: @cond_var.Cond::Cond(), }
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
    assert_eq(session.messages.length(), 2)
    assert_true(session.messages[0] is UserMessage(content=[Text("task"), ..]))
    assert_true(
      session.messages[1] is AssistantMessage(content=[Text("resumed"), ..], ..),
    )
    let retried = model.received_messages[1]
    assert_eq(retried.length(), 1)
    assert_true(retried[0] is UserMessage(content=[Text("task"), ..]))
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
  let model : DelayedModel = { delay_ms: 150, started: 0, finished: 0, }
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
  let observer : &@posoco.Observer = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(40000L)))
  observer.on_event_at(
    Some(test_scope("s1")),
    @posoco.TurnEvent::TurnFailed("quota"),
  )
  hook.on_post_event_at(Some(test_scope("s2")), quota_failure(Some(40000L)))
  observer.on_event_at(
    Some(test_scope("s2")),
    @posoco.TurnEvent::TurnFailed("quota"),
  )
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
async test "non-rate resume failure is observable and is not retried" {
  let traces : Array[String] = []
  let model = @posoco.ScriptedModel::ScriptedModel([
    @posoco.ScriptedModelStep::Fail(
      @posoco.ModelError::Transport("resume exploded"),
    ),
    @posoco.ScriptedModelStep::Respond(@posoco.tk_stop_response("ok")),
  ])
  let guard_ext = RateLimitGuard(margin_ms=0, now_ms=fn() { 30000L }, trace=fn(
    line : String,
  ) {
    traces.push(line)
  })
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
  let observer : &@posoco.Observer = guard_ext
  observer.on_event_at(
    Some(test_scope("s1")),
    @posoco.TurnEvent::TurnFailed("quota"),
  )
  let outcome : Result[Unit, Error] = Ok(guard_ext.poll()) catch {
    error => Err(error)
  }
  assert_true(outcome is Err(_))
  assert_eq(model.call_count(), 1)
  assert_eq(guard_ext.pending_snapshots().length(), 0)
  assert_true(
    traces.any(fn(line) {
      line.contains("failed without retry") && line.contains("resume exploded")
    }),
  )
}

///|
/// Host-style teardown error: raised by the group body to model a host
/// abort (cetas-acp stdin EOF), which puts the group into failure and
/// cancels every remaining child mid-flight.
suberror HostEof derive(Debug)

///|
/// Cancellation regression: when a host group tears down (cetas-acp stdin
/// EOF), the aborting body fails the group and the monitor is cancelled
/// mid-sleep; the loop must re-raise the cancellation so the teardown
/// completes. Swallowing it used to spin the idle monitor forever — the
/// sleep is the loop's only suspension point. The real injected sleep is
/// used (no virtual clock), the with_timeout watchdog bounds the assertion,
/// and `stopped` staying false proves the exit came from cancellation,
/// not stop().
async test "spawn_monitor terminates on task group cancellation" {
  let guard_ext = RateLimitGuard(poll_interval_ms=1)
  let outcome : Result[Unit, Error] = Ok(
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        guard_ext.spawn_monitor(group)
        @async.sleep(10)
        raise HostEof
      })
    }),
  ) catch {
    error => Err(error)
  }
  guard outcome is Err(error) else {
    fail("expected the host abort to propagate out of the group")
  }
  assert_true(error is HostEof)
  assert_true(!guard_ext.stopped)
}

///|
/// Capture subscriber over a real bus: every published event is decoded
/// back into a StatusOp.
priv struct BusCapture {
  events : Array[@devkit.BusEvent]
}

///|
fn BusCapture::BusCapture() -> BusCapture {
  { events: [], }
}

///|
impl @devkit.BusSubscriber for BusCapture with fn on_bus_event(
  self : BusCapture,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
async test "429 with reset time announces the resume reset moment" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let guard_ext = RateLimitGuard(margin_ms=15000, bus=Some(bus), now_ms=fn() {
    1000L
  })
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(900000L)))
  // resume_at 915000 -> 1970-01-01T00:15:15Z.
  assert_eq(capture.events.length(), 1)
  assert_eq(capture.events[0].source, "posoco_ext_ratelimit")
  assert_eq(capture.events[0].topic, "status")
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="🕐 reset",
        label=None,
        priority=90,
        value=Some("1970-01-01T00:15:15Z"),
        color=Some("warning"),
      ),
    ),
  )
}

///|
async test "TurnCompleted after a pending resume unregisters the segment" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let guard_ext = RateLimitGuard(margin_ms=1000, bus=Some(bus), now_ms=fn() {
    1000L
  })
  let hook : &@posoco.PipelineHook = guard_ext
  let observer : &@posoco.Observer = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(50000L)))
  observer.on_event_at(Some(test_scope("s1")), @posoco.TurnEvent::TurnCompleted)
  assert_eq(capture.events.length(), 2)
  assert_true(
    @devkit.decode_status_op(capture.events[0])
    is Some(@devkit.StatusOp::Register(..)),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(@devkit.StatusOp::Unregister(segment="🕐 reset")),
  )
}

///|
async test "giving up over max_attempts unregisters the segment" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let guard_ext = RateLimitGuard(max_attempts=1, margin_ms=0, bus=Some(bus), now_ms=fn() {
    1000L
  })
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(61000L)))
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="🕐 reset",
        label=None,
        priority=90,
        value=Some("1970-01-01T00:01:01Z"),
        color=Some("warning"),
      ),
    ),
  )
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(71000L)))
  assert_eq(capture.events.length(), 2)
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(@devkit.StatusOp::Unregister(segment="🕐 reset")),
  )
}

///|
async test "published reset moment reflects the earliest pending resume" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let guard_ext = RateLimitGuard(margin_ms=0, bus=Some(bus), now_ms=fn() {
    1000L
  })
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("late")), quota_failure(Some(301000L)))
  hook.on_post_event_at(Some(test_scope("early")), quota_failure(Some(11000L)))
  assert_eq(capture.events.length(), 2)
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="🕐 reset",
        label=None,
        priority=90,
        value=Some("1970-01-01T00:05:01Z"),
        color=Some("warning"),
      ),
    ),
  )
  // The latest publish tracks the earliest schedule, not the last verdict.
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(
      @devkit.StatusOp::Register(
        segment="🕐 reset",
        label=None,
        priority=90,
        value=Some("1970-01-01T00:00:11Z"),
        color=Some("warning"),
      ),
    ),
  )
}

///|
async test "a second 429 updates the same session's reset moment in place" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let guard_ext = RateLimitGuard(margin_ms=0, bus=Some(bus), now_ms=fn() {
    1000L
  })
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(61000L)))
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(121000L)))
  assert_eq(guard_ext.pending_snapshots().length(), 1)
  // One fresh Register per verdict: the update-in-place republishes the
  // rescheduled reset moment.
  assert_eq(capture.events.length(), 2)
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="🕐 reset",
        label=None,
        priority=90,
        value=Some("1970-01-01T00:01:01Z"),
        color=Some("warning"),
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(
      @devkit.StatusOp::Register(
        segment="🕐 reset",
        label=None,
        priority=90,
        value=Some("1970-01-01T00:02:01Z"),
        color=Some("warning"),
      ),
    ),
  )
}

///|
async test "resume value is a pure function of the schedule, not the clock" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let now = Ref(1000L)
  let guard_ext = RateLimitGuard(margin_ms=0, bus=Some(bus), now_ms=fn() {
    now.val
  })
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(3601000L)))
  now.val = 2000L
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(2500L)))
  assert_eq(capture.events.length(), 2)
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="🕐 reset",
        label=None,
        priority=90,
        value=Some("1970-01-01T01:00:01Z"),
        color=Some("warning"),
      ),
    ),
  )
  // Five seconds of clock drift between verdicts changes nothing: the
  // announced value depends only on the schedule, so it never goes stale
  // and never needs a refresh.
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(
      @devkit.StatusOp::Register(
        segment="🕐 reset",
        label=None,
        priority=90,
        value=Some("1970-01-01T00:00:02Z"),
        color=Some("warning"),
      ),
    ),
  )
}

///|
test "reset formatting covers epoch zero, day rollover, and leap years" {
  assert_eq(fmt_reset_at(0L), "1970-01-01T00:00:00Z")
  assert_eq(fmt_reset_at(86399999L), "1970-01-01T23:59:59Z")
  assert_eq(fmt_reset_at(86400000L), "1970-01-02T00:00:00Z")
  assert_eq(fmt_reset_at(946684800000L), "2000-01-01T00:00:00Z")
  assert_eq(fmt_reset_at(951696000000L), "2000-02-28T00:00:00Z")
  assert_eq(fmt_reset_at(951782400000L), "2000-02-29T00:00:00Z")
  assert_eq(fmt_reset_at(1770000000000L), "2026-02-02T02:40:00Z")
}

///|
async test "a verdict naming the 5-hour window announces 🕐 5h reset" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let guard_ext = RateLimitGuard(margin_ms=15000, bus=Some(bus), now_ms=fn() {
    1000L
  })
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(
    Some(test_scope("s1")),
    quota_failure_with(
      "You've reached your 5-hour usage limit. Try again later.",
      Some(900000L),
    ),
  )
  // resume_at 915000 -> 1970-01-01T00:15:15Z.
  assert_eq(capture.events.length(), 1)
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="🕐 5h reset",
        label=None,
        priority=90,
        value=Some("1970-01-01T00:15:15Z"),
        color=Some("warning"),
      ),
    ),
  )
  // The release after the turn completes must name the labelled segment.
  let observer : &@posoco.Observer = guard_ext
  observer.on_event_at(Some(test_scope("s1")), @posoco.TurnEvent::TurnCompleted)
  assert_eq(capture.events.length(), 2)
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(@devkit.StatusOp::Unregister(segment="🕐 5h reset")),
  )
}

///|
async test "a window-label change releases the old segment name" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let guard_ext = RateLimitGuard(margin_ms=0, bus=Some(bus), now_ms=fn() {
    1000L
  })
  let hook : &@posoco.PipelineHook = guard_ext
  hook.on_post_event_at(Some(test_scope("late")), quota_failure(Some(301000L)))
  // An earlier 5h-window verdict takes over the announcement: the unnamed
  // segment is released before the labelled one registers — the bridge keys
  // ownership by segment name and would otherwise list both.
  hook.on_post_event_at(
    Some(test_scope("early")),
    quota_failure_with("current 5-hour window", Some(11000L)),
  )
  assert_eq(capture.events.length(), 3)
  assert_true(
    @devkit.decode_status_op(capture.events[0])
    is Some(@devkit.StatusOp::Register(segment="🕐 reset", ..)),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(@devkit.StatusOp::Unregister(segment="🕐 reset")),
  )
  assert_true(
    @devkit.decode_status_op(capture.events[2])
    is Some(@devkit.StatusOp::Register(segment="🕐 5h reset", ..)),
  )
}

///|
async test "a fired resume republishes the reset moment for the remaining session" {
  let bus = @devkit.EventBus()
  let capture = BusCapture::BusCapture()
  bus.subscribe(capture)
  let now = Ref(1000L)
  let guard_ext = RateLimitGuard(margin_ms=0, bus=Some(bus), now_ms=fn() {
    now.val
  })
  let hook : &@posoco.PipelineHook = guard_ext
  let observer : &@posoco.Observer = guard_ext
  hook.on_post_event_at(Some(test_scope("s1")), quota_failure(Some(11000L)))
  observer.on_event_at(
    Some(test_scope("s1")),
    @posoco.TurnEvent::TurnFailed("quota"),
  )
  hook.on_post_event_at(Some(test_scope("s2")), quota_failure(Some(301000L)))
  observer.on_event_at(
    Some(test_scope("s2")),
    @posoco.TurnEvent::TurnFailed("quota"),
  )
  // An empty take (nothing due) publishes nothing — the monitor polls every
  // interval and must not emit no-op events.
  assert_eq(guard_ext.take_due(now.val).length(), 0)
  assert_eq(capture.events.length(), 2)
  now.val = 20000L
  let fired = guard_ext.take_due(now.val)
  assert_eq(fired.length(), 1)
  assert_eq(fired[0].session_id, "s1")
  // s2 resumes at 301000 -> 1970-01-01T00:05:01Z.
  assert_eq(
    @devkit.decode_status_op(capture.events[2]),
    Some(
      @devkit.StatusOp::Register(
        segment="🕐 reset",
        label=None,
        priority=90,
        value=Some("1970-01-01T00:05:01Z"),
        color=Some("warning"),
      ),
    ),
  )
}
