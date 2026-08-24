///|
/// One scheduled recovery: the session whose turn died on a 429, the
/// provider-stated reset time.
struct PendingResume {
  session_id : String
  resume_at_ms : Int64
  attempts : Int
  provider_code : String?
}

///|
fn find_pending(
  pending : Array[PendingResume],
  session_id : String,
) -> PendingResume? {
  for entry in pending {
    if entry.session_id == session_id {
      return Some(entry)
    }
  }
  None
}

///|
/// Read-only view of a pending recovery, for hosts and tests.
pub(all) struct RateLimitPending {
  session_id : String
  resume_at_ms : Int64
  attempts : Int
  provider_code : String?
} derive(Eq, Debug)

///|
/// Records provider quota verdicts (HTTP 429 with a stated reset time) per
/// session and re-runs the interrupted turn once the reset time passes.
///
/// A failed turn owns its transcript: the Agent persists the user input and
/// any completed progress to the session store even when the turn dies. So
/// resuming does NOT resend the original input — that would duplicate it —
/// but sends a short continue note (`resume_note`). The rehydrated transcript
/// carries the task context; the model selection is the same because the
/// same agent/router serves the new turn.
///
/// Wiring:
/// 1. put the guard in the Agent's extensions (it contributes a
///    `PipelineHook`, `Observer` and `Lifecycle`);
/// 2. call `bind(agent)` after the Agent exists;
/// 3. call `spawn_monitor(group)` with a host-owned task group — MoonBit
///    async has no detached spawn, so the background timer lives in the
///    host's group (same pattern as posoco-ext-acp's `spawn_pump`).
///
/// Verdicts without a reset time (`reset_at_ms = None`, e.g. transient
/// concurrency 429s) are ignored: nothing is schedulable.
///
/// # Example
/// ```mbt nocheck
/// let guard = RateLimitGuard()
/// let agent = @posoco.Agent(exts=[guard], config=@posoco.tk_config())
/// guard.bind(agent)
/// @async.with_task_group(group => guard.spawn_monitor(group))
/// ```
pub struct RateLimitGuard {
  mut agent : @posoco.Agent?
  mut pending : Array[PendingResume]
  attempts : Map[String, Int]
  mut stopped : Bool
  resume_note : String
  margin_ms : Int64
  max_attempts : Int
  poll_interval_ms : Int
  probe_interval_ms : Int64
  now_ms : () -> Int64
  trace : (String) -> Unit
}

///|
pub fn RateLimitGuard::RateLimitGuard(
  resume_note? : String = "The previous request was interrupted by a provider rate limit. Continue that task.",
  margin_ms? : Int64 = 15000,
  max_attempts? : Int = 3,
  poll_interval_ms? : Int = 500,
  probe_interval_ms? : Int64 = 900000,
  now_ms? : () -> Int64 = fn() { @async.now() },
  trace? : (String) -> Unit = fn(_ : String) { () },
) -> RateLimitGuard {
  {
    agent: None,
    pending: [],
    attempts: Map::from_array([]),
    stopped: false,
    resume_note,
    margin_ms,
    max_attempts,
    poll_interval_ms,
    probe_interval_ms,
    now_ms,
    trace,
  }
}

///|
pub fn RateLimitGuard::bind(
  self : RateLimitGuard,
  agent : @posoco.Agent,
) -> Unit {
  self.agent = Some(agent)
}

///|
pub fn RateLimitGuard::stop(self : RateLimitGuard) -> Unit {
  self.stopped = true
}

///|
pub fn RateLimitGuard::pending_snapshots(
  self : RateLimitGuard,
) -> Array[RateLimitPending] {
  self.pending.map(fn(entry) {
    {
      session_id: entry.session_id,
      resume_at_ms: entry.resume_at_ms,
      attempts: entry.attempts,
      provider_code: entry.provider_code,
    }
  })
}

///|
fn copy_user_message(message : @posoco.Message) -> @posoco.Message {
  match message {
    UserMessage(content~) =>
      @posoco.Message::UserMessage(content=content.copy())
    other => other
  }
}

///|
fn RateLimitGuard::record_limit(
  self : RateLimitGuard,
  session_id : String,
  reset_at_ms : Int64?,
  provider_code : String?,
) -> Unit {
  let prior = match self.attempts.get(session_id) {
    Some(count) => count + 1
    None => 1
  }
  self.attempts[session_id] = prior
  if prior > self.max_attempts {
    self.pending = self.pending.filter(fn(entry) {
      entry.session_id != session_id
    })
    (self.trace)(
      "rate-limit resume gave up on session \{session_id} after \{prior} attempts",
    )
    return
  }
  // A verdict with no stated reset time (Kimi's "quota will be refreshed in
  // the next period") is only recoverable by probing: retry after a backing
  // off interval instead of a provider-stated timestamp.
  let resume_at = match reset_at_ms {
    Some(reset) => reset + self.margin_ms
    None => {
      if self.probe_interval_ms <= 0L {
        return
      }
      let shift : Int = if prior - 1 > 4 { 4 } else { prior - 1 }
      let mut backoff = self.probe_interval_ms << shift
      if backoff > 3600000L {
        backoff = 3600000L
      }
      (self.now_ms)() + backoff
    }
  }
  let already = find_pending(self.pending, session_id) is Some(_)
  if already {
    self.pending = self.pending.map(fn(entry) {
      if entry.session_id == session_id {
        { ..entry, resume_at_ms: resume_at, attempts: prior, provider_code }
      } else {
        entry
      }
    })
  } else {
    self.pending.push({
      session_id,
      resume_at_ms: resume_at,
      attempts: prior,
      provider_code,
    })
  }
  (self.trace)(
    "rate limit on session \{session_id} (code=\{to_repr(provider_code)}), resume scheduled at \{resume_at}",
  )
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
      ModelFailed(failure=RateLimited(reset_at_ms~, provider_code~, ..)),
    ) =>
      self.record_limit(
        scope.session_id.to_string(),
        reset_at_ms,
        provider_code,
      )
    _ => ()
  }
}

///|
pub impl @posoco.Observer for RateLimitGuard with fn on_event_at(
  self : RateLimitGuard,
  scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match (scope, event) {
    (Some(scope), TurnCompleted) => {
      self.attempts.remove(scope.session_id.to_string())
      self.pending = self.pending.filter(fn(entry) {
        entry.session_id != scope.session_id.to_string()
      })
    }
    _ => ()
  }
}

///|
pub impl @posoco.Lifecycle for RateLimitGuard with fn on_shutdown(
  self : RateLimitGuard,
) -> Unit {
  self.stopped = true
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
  {
    id: "posoco_ext_ratelimit",
    models: [],
    tools: [],
    sessions: [],
    observers: [self],
    hooks: [self],
    memory: [],
    lifecycle: [self],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
pub extend RateLimitGuard with @posoco.Extension::{extension_id, manifest}

///|
/// Resume every due entry now. A resumed turn that 429s again re-records
/// itself via the hook; any other failure is retried after a short delay
/// until `max_attempts` is exhausted.
async fn RateLimitGuard::poll_due(
  self : RateLimitGuard,
  now_ms : Int64,
) -> Unit {
  let due = self.pending.filter(fn(entry) {
    entry.resume_at_ms <= now_ms && !self.stopped
  })
  for entry in due {
    self.pending = self.pending.filter(fn(other) {
      other.session_id != entry.session_id
    })
    let agent = match self.agent {
      Some(agent) => agent
      None => {
        (self.trace)(
          "rate-limit resume skipped for session \{entry.session_id}: no agent bound",
        )
        continue
      }
    }
    let input = @posoco.Message::UserMessage(content=[
      @posoco.Content::Text(self.resume_note),
    ])
    let outcome : Result[@posoco.TurnResult, @posoco.AgentError] = Ok(
      agent.run_turn(input, entry.session_id),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Ok(_) => ()
      Err(_) => {
        let re_recorded = find_pending(self.pending, entry.session_id)
        match re_recorded {
          Some(_) => ()
          None => {
            let prior = match self.attempts.get(entry.session_id) {
              Some(count) => count + 1
              None => 2
            }
            self.attempts[entry.session_id] = prior
            if prior <= self.max_attempts {
              self.pending.push({
                session_id: entry.session_id,
                resume_at_ms: now_ms + 2000,
                attempts: prior,
                provider_code: entry.provider_code,
              })
              (self.trace)(
                "rate-limit resume failed for session \{entry.session_id}, retry scheduled",
              )
            } else {
              (self.trace)(
                "rate-limit resume gave up on session \{entry.session_id}",
              )
            }
          }
        }
      }
    }
  }
}

///|
/// Run one resume cycle synchronously. Hosts that already own a periodic
/// loop can drive this instead of `spawn_monitor`.
pub async fn RateLimitGuard::poll(self : RateLimitGuard) -> Unit {
  self.poll_due((self.now_ms)())
}

///|
/// Spawn the background timer loop into a host-owned task group.
pub fn[G] RateLimitGuard::spawn_monitor(
  self : RateLimitGuard,
  group : @async.TaskGroup[G],
) -> Unit {
  group.spawn_bg(() => {
    while !self.stopped {
      self.poll_due((self.now_ms)()) catch {
        _ => ()
      }
      let now = (self.now_ms)()
      let mut delay = self.poll_interval_ms
      for entry in self.pending {
        if entry.resume_at_ms > now {
          let delta = entry.resume_at_ms - now
          let delta_int = if delta > 2147483647L {
            2147483647
          } else {
            delta.to_int()
          }
          if delta_int < delay {
            delay = delta_int
          }
        }
      }
      if delay < 1 {
        delay = 1
      }
      @async.sleep(delay) catch {
        _ => ()
      }
    }
  })
}
