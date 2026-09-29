///|
/// Posoco adapter for the rate-limit runtime.
///
/// All recovery business state belongs to the Fuwaroid runtime. The guard
/// only translates Posoco hook/observer/lifecycle events into runtime
/// commands and owns startup wiring.
pub struct RateLimitGuard {
  priv mut agent : @posoco.Agent?
  priv mut runtime : RateLimitRuntime?
  priv resume_note : String
  priv policy : RecoveryPolicy
  priv now_ms : () -> Int64
  priv sleep_ms : async (Int) -> Unit
  priv trace : (String) -> Unit
  priv status_sink : DevkitStatusSink
  priv shutdown_timeout_ms : Int
}

///|
/// Compatibility-friendly constructor. poll_interval_ms is accepted so 0.3
/// callers still compile, but event-driven scheduling no longer polls.
pub fn RateLimitGuard::RateLimitGuard(
  resume_note? : String = "continue",
  margin_ms? : Int64 = 0,
  max_attempts? : Int = 3,
  poll_interval_ms? : Int = 500,
  probe_interval_ms? : Int64 = 900000,
  max_probe_interval_ms? : Int64 = 3600000,
  shutdown_timeout_ms? : Int = 5000,
  now_ms? : () -> Int64 = fn() { @async.now() },
  sleep_ms? : async (Int) -> Unit = async fn(ms : Int) { @async.sleep(ms) },
  trace? : (String) -> Unit = fn(_ : String) { () },
  bus? : @devkit.EventBus? = None,
) -> RateLimitGuard {
  ignore(poll_interval_ms)
  {
    agent: None,
    runtime: None,
    resume_note,
    policy: {
      margin_ms,
      max_attempts,
      probe_interval_ms,
      max_probe_interval_ms,
    },
    now_ms,
    sleep_ms,
    trace,
    status_sink: DevkitStatusSink(bus),
    shutdown_timeout_ms,
  }
}

///|
/// Bind only the Posoco executor. Kept for 0.3 wiring compatibility; prefer
/// start(group~, agent~), which binds and starts in one call.
pub fn RateLimitGuard::bind(
  self : RateLimitGuard,
  agent : @posoco.Agent,
) -> Unit {
  self.agent = Some(agent)
}

///|
/// Start the serialized runtime and its Supervisor on the host task group.
pub fn RateLimitGuard::start(
  self : RateLimitGuard,
  group~ : @async.TaskGroup[Unit],
  agent~ : @posoco.Agent,
) -> Unit {
  self.agent = Some(agent)
  if self.runtime is Some(_) {
    return
  }
  let note = self.resume_note
  let sink = self.status_sink
  let runtime = RateLimitRuntime::start(
    group~,
    policy=self.policy,
    now_ms=self.now_ms,
    sleep_ms=self.sleep_ms,
    resume=async fn(session_id : String) {
      ignore(agent.resume_turn(session_id, continuation=note))
    },
    trace=self.trace,
    publish_status=fn(status : RecoveryStatus?) {
      sink.publish(status)
    },
  )
  self.runtime = Some(runtime)
}

///|
/// Deprecated compatibility wrapper. It no longer spawns a polling monitor;
/// it starts the event-driven runtime on the supplied host group.
pub fn RateLimitGuard::spawn_monitor(
  self : RateLimitGuard,
  group : @async.TaskGroup[Unit],
) -> Unit {
  let agent = match self.agent {
    Some(agent) => agent
    None => fail("rate-limit guard must bind(agent) before spawn_monitor(group)")
  }
  self.start(group~, agent~)
}

///|
/// Compatibility seam for hosts that previously drove poll() themselves.
/// Internal scheduling is event-driven; Poll only asks the actor to dispatch
/// anything already due at the injected clock.
pub async fn RateLimitGuard::poll(self : RateLimitGuard) -> Unit {
  match self.runtime {
    Some(runtime) => {
      runtime.tell(Poll(now_ms=(self.now_ms)()))
      runtime.barrier()
    }
    None => ()
  }
}

///|
/// Actor-consistent read-only snapshot.
pub async fn RateLimitGuard::snapshot(
  self : RateLimitGuard,
) -> Array[RateLimitPending] {
  match self.runtime {
    Some(runtime) => runtime.snapshot()
    None => []
  }
}

///|
/// Invalidate all pending and in-flight tickets. A late worker report or a
/// late 429 from the invalidated recovery is ignored by epoch checks.
pub fn RateLimitGuard::cancel_pending(self : RateLimitGuard) -> Unit {
  match self.runtime {
    Some(runtime) => runtime.tell(CancelPending)
    None => self.status_sink.publish(None)
  }
}

///|
/// Stop admitting recovery decisions. Prefer shutdown() when the caller can
/// await bounded Supervisor settlement.
pub fn RateLimitGuard::stop(self : RateLimitGuard) -> Unit {
  match self.runtime {
    Some(runtime) => runtime.tell(Stop)
    None => ()
  }
}

///|
/// Stop the actor, cancel supervised timers/workers and wait up to the
/// configured settlement deadline.
pub async fn RateLimitGuard::shutdown(self : RateLimitGuard) -> Unit {
  match self.runtime {
    Some(runtime) => {
      runtime.shutdown(self.shutdown_timeout_ms)
      self.runtime = None
      self.status_sink.publish(None)
    }
    None => ()
  }
}

///|
/// Whether needle starts at at in text.
fn starts_at(text : String, at : Int, needle : String) -> Bool {
  if at + needle.length() > text.length() {
    return false
  }
  for i in 0..<needle.length() {
    if text[at + i] != needle[i] {
      return false
    }
  }
  true
}

///|
/// Conservative parser for the 5-hour quota-window label used by status UI.
fn five_hour_label(message : String) -> String? {
  let text = message.to_lower()
  let n = text.length()
  for i in 0..<n {
    if text[i] != '5' || (i > 0 && text[i - 1] >= '0' && text[i - 1] <= '9') {
      continue
    }
    let mut j = i + 1
    if j < n && (text[j] == '-' || text[j] == ' ') {
      j += 1
    }
    if j < n && text[j] == 'h' {
      while j < n && text[j] >= 'a' && text[j] <= 'z' {
        j += 1
      }
      let lookahead = if j + 24 < n { j + 24 } else { n }
      let mut k = j
      while k < lookahead {
        if starts_at(text, k, "window") ||
          starts_at(text, k, "usage limit") ||
          starts_at(text, k, "period") {
          return Some("5h")
        }
        k += 1
      }
    }
  }
  None
}

///|
fn RateLimitGuard::send(
  self : RateLimitGuard,
  command : RecoveryCommand,
) -> Unit {
  match self.runtime {
    Some(runtime) => runtime.tell(command)
    None =>
      (self.trace)(
        "rate-limit event ignored before start(group, agent)",
      )
  }
}

///|
pub impl @posoco.PipelineHook for RateLimitGuard with fn on_post_event_at(
  self : RateLimitGuard,
  scope : @posoco.EventScope?,
  stage : @posoco.HookStage,
) -> Unit {
  match (scope, stage) {
    (
      Some(scope),
      ModelFailed(failure=RateLimited(reset_at_ms~, provider_code~, reason~)),
    ) =>
      self.send(
        RateLimitObserved(
          session_id=scope.session_id.to_string(),
          reset_at_ms~,
          provider_code~,
          window_label=five_hour_label(reason),
          encountered_at_ms=(self.now_ms)(),
        ),
      )
    _ => ()
  }
}

///|
pub extend RateLimitGuard with @posoco.PipelineHook::{
  on_post_event,
  on_turn_begin,
  on_post_event_at,
  before_model,
  before_tool,
  on_turn_end,
}

///|
pub impl @posoco.Observer for RateLimitGuard with fn on_event_at(
  self : RateLimitGuard,
  scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match (scope, event) {
    (Some(scope), TurnFailed(_)) =>
      self.send(TurnFailed(session_id=scope.session_id.to_string()))
    (Some(scope), TurnCompleted) =>
      self.send(TurnCompleted(session_id=scope.session_id.to_string()))
    _ => ()
  }
}

///|
pub extend RateLimitGuard with @posoco.Observer::{on_event, on_event_at}

///|
pub impl @posoco.Lifecycle for RateLimitGuard with fn on_shutdown(
  self : RateLimitGuard,
) -> Unit {
  let _ = @async.protect_from_cancel(() => self.shutdown())
}

///|
pub extend RateLimitGuard with @posoco.Lifecycle::{
  on_compose,
  on_shutdown,
  on_start,
}

///|
pub impl @posoco.Extension for RateLimitGuard with fn extension_id(
  _self : RateLimitGuard,
) -> String {
  "posoco_ext_ratelimit"
}

///|
pub impl @posoco.Extension for RateLimitGuard with fn manifest(
  self : RateLimitGuard,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_ratelimit",
    observers=[self],
    hooks=[self],
    lifecycle=[self],
  )
}

///|
pub extend RateLimitGuard with @posoco.Extension::{extension_id, manifest}
