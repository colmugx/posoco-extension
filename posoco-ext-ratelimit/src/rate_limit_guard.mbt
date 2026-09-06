///|
/// One scheduled recovery: the session whose turn died on a 429, the
/// provider-stated reset time.
struct PendingResume {
  session_id : String
  encountered_at_ms : Int64
  reset_at_ms : Int64?
  resume_at_ms : Int64
  attempts : Int
  provider_code : String?
  window_label : String?
  generation : Int
  /// The rate-limit hook runs before Agent persists the failed turn. Recovery
  /// becomes eligible only after the scoped TurnFailed boundary arrives.
  recovery_ready : Bool
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
  encountered_at_ms : Int64
  reset_at_ms : Int64?
  resume_at_ms : Int64
  attempts : Int
  provider_code : String?
} derive(Eq, Debug)

///|
/// Records provider quota verdicts (HTTP 429 with a stated reset time) per
/// session and re-runs the interrupted turn once the reset time passes.
///
/// A failed turn owns its transcript: the Agent persists the user input and
/// any completed progress to the session store even when the turn dies. The
/// Agent replays a trailing user message without appending it again; when
/// assistant or tool progress follows, it appends the short continuation note
/// (`resume_note`). The same agent/router serves the new turn.
///
/// Wiring:
/// 1. put the guard in the Agent's extensions (it contributes a
///    `PipelineHook`, `Observer` and `Lifecycle`);
/// 2. call `bind(agent)` after the Agent exists;
/// 3. call `spawn_monitor(group)` with a host-owned task group — MoonBit
///    async has no detached spawn, so the background timer lives in the
///    host's group.
///
/// Verdicts without a reset time (`reset_at_ms = None`) use the configured
/// probe interval and backoff. Set `probe_interval_ms = 0` to leave them
/// unscheduled.
///
/// Both time sources are injectable (`now_ms`, `sleep_ms`), so tests can
/// drive a virtual clock instead of waiting real milliseconds.
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
  mut generation : Int
  mut active_resume_generation : Int?
  resume_note : String
  margin_ms : Int64
  max_attempts : Int
  poll_interval_ms : Int
  probe_interval_ms : Int64
  now_ms : () -> Int64
  sleep_ms : async (Int) -> Unit
  turn_lock : @semaphore.Semaphore
  trace : (String) -> Unit
  /// Optional cross-extension bus: after every schedule change the guard
  /// republishes the reset status segment (devkit status protocol) so a
  /// status bar can show when the interrupted task restarts.
  bus : @devkit.EventBus?
  /// The segment name currently on the bar, if any. The name carries the
  /// window label (`🕐 5h reset` vs `🕐 reset`), so releasing the segment
  /// later must use the exact name that was registered.
  priv mut announced : String?
}

///|
pub fn RateLimitGuard::RateLimitGuard(
  resume_note? : String = "continue",
  margin_ms? : Int64 = 0,
  max_attempts? : Int = 3,
  poll_interval_ms? : Int = 500,
  probe_interval_ms? : Int64 = 900000,
  now_ms? : () -> Int64 = fn() { @async.now() },
  sleep_ms? : async (Int) -> Unit = async fn(ms : Int) { @async.sleep(ms) },
  trace? : (String) -> Unit = fn(_ : String) { () },
  bus? : @devkit.EventBus? = None,
) -> RateLimitGuard {
  {
    agent: None,
    pending: [],
    attempts: Map::from_array([]),
    stopped: false,
    generation: 0,
    active_resume_generation: None,
    resume_note,
    margin_ms,
    max_attempts,
    poll_interval_ms,
    probe_interval_ms,
    now_ms,
    sleep_ms,
    turn_lock: @semaphore.Semaphore::Semaphore(1),
    trace,
    bus,
    announced: None,
  }
}

///|
/// The status-bar segment announcing the quota reset: `🕐 reset`, or
/// `🕐 5h reset` when the verdict named the 5-hour window.
fn reset_segment(window_label : String?) -> String {
  match window_label {
    Some(label) => "🕐 \{label} reset"
    None => "🕐 reset"
  }
}

///|
/// Whether `needle` starts at `at` in `text` (lowercase both sides).
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
/// The quota window the verdict message names, for the status segment:
/// a "5 hour(s)" / "5h" length with a window keyword nearby ("5-hour usage
/// limit", "current 5-hour window") — the same convention chat-completions
/// uses to bound a reset time — yields `Some("5h")`. Any other naming
/// (weekly limits, relative "in 5 hours" phrasing without a window
/// keyword) stays unnamed: a wrong label is worse than no label.
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
/// Republish the reset status segment after a schedule change: with
/// nothing pending the segment is released, otherwise it registers the
/// earliest resume moment as an absolute UTC timestamp. The value is a
/// pure function of the schedule — no countdown math against the current
/// clock, so one publish per schedule change stays correct forever and
/// nothing needs periodic re-renders. Local-time
/// rendering of that timestamp is the host's job, not the guard's.
///
/// The segment name carries the window label, so a label change means a
/// new name: the previous one is released first — the bridge keys
/// ownership by segment name and would otherwise list both.
fn RateLimitGuard::publish_resume_status(self : RateLimitGuard) -> Unit {
  let bus = match self.bus {
    Some(bus) => bus
    None => return
  }
  let next : (String, String)? = if self.pending.is_empty() {
    None
  } else {
    let mut earliest = self.pending[0]
    for entry in self.pending {
      if entry.resume_at_ms < earliest.resume_at_ms {
        earliest = entry
      }
    }
    Some(
      (
        reset_segment(earliest.window_label),
        fmt_reset_at(earliest.resume_at_ms),
      ),
    )
  }
  match (self.announced, next) {
    (Some(previous), Some((segment, _))) =>
      if previous != segment {
        @devkit.publish_status_unregister(
          bus,
          source="posoco_ext_ratelimit",
          segment=previous,
        )
      }
    (Some(previous), None) =>
      @devkit.publish_status_unregister(
        bus,
        source="posoco_ext_ratelimit",
        segment=previous,
      )
    (None, _) => ()
  }
  match next {
    Some((segment, value)) => {
      @devkit.publish_status_register(
        bus,
        source="posoco_ext_ratelimit",
        segment~,
        priority=90,
        value~,
        color="warning",
      )
      self.announced = Some(segment)
    }
    None => self.announced = None
  }
}

///|
/// Days to civil date (Howard Hinnant's algorithm); pure integer math so
/// timezone-free timestamps convert without a datetime dependency.
fn civil_from_days(z : Int64) -> (Int64, Int, Int) {
  let z = z + 719468L
  let era = if z >= 0L { z / 146097L } else { (z - 146096L) / 146097L }
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  let year = if m <= 2L { y + 1L } else { y }
  (year, m.to_int(), d.to_int())
}

///|
fn pad2(value : Int64) -> String {
  if value < 10L {
    "0\{value}"
  } else {
    "\{value}"
  }
}

///|
/// Reset announcement for the status bar: the absolute resume moment as
/// UTC ISO-8601 ("2026-09-04T00:15:26Z"), matching the session segment's
/// UTC timestamp convention.
fn fmt_reset_at(reset_at_ms : Int64) -> String {
  let total_s = reset_at_ms / 1000L
  let days = total_s / 86400L
  let rem = total_s - days * 86400L
  let (year, month, day) = civil_from_days(days)
  "\{year}-\{pad2(month.to_int64())}-\{pad2(day.to_int64())}T\{pad2(rem / 3600L)}:\{pad2(rem % 3600L / 60L)}:\{pad2(rem % 60L)}Z"
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
  self.cancel_pending()
}

///|
/// Invalidate every pending or already-taken recovery ticket. The monitor
/// remains available for future turns; `stop()` additionally ends it.
pub fn RateLimitGuard::cancel_pending(self : RateLimitGuard) -> Unit {
  self.generation = self.generation + 1
  self.pending = []
  self.attempts.clear()
  self.publish_resume_status()
  (self.trace)("rate-limit recovery pending work cancelled")
}

///|
pub fn RateLimitGuard::pending_snapshots(
  self : RateLimitGuard,
) -> Array[RateLimitPending] {
  self.pending.map(fn(entry) {
    {
      session_id: entry.session_id,
      encountered_at_ms: entry.encountered_at_ms,
      reset_at_ms: entry.reset_at_ms,
      resume_at_ms: entry.resume_at_ms,
      attempts: entry.attempts,
      provider_code: entry.provider_code,
    }
  })
}

///|
fn RateLimitGuard::record_limit(
  self : RateLimitGuard,
  session_id : String,
  reset_at_ms : Int64?,
  provider_code : String?,
  window_label~ : String?,
) -> Unit {
  match self.active_resume_generation {
    Some(generation) if generation != self.generation => {
      (self.trace)("ignored stale rate-limit failure for session \{session_id}")
      return
    }
    _ => ()
  }
  let encountered_at_ms = (self.now_ms)()
  let prior = match self.attempts.get(session_id) {
    Some(count) => count + 1
    None => 1
  }
  self.attempts[session_id] = prior
  if prior > self.max_attempts {
    self.pending = self.pending.filter(fn(entry) {
      entry.session_id != session_id
    })
    self.publish_resume_status()
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
      encountered_at_ms + backoff
    }
  }
  let already = find_pending(self.pending, session_id) is Some(_)
  if already {
    self.pending = self.pending.map(fn(entry) {
      if entry.session_id == session_id {
        {
          ..entry,
          encountered_at_ms,
          reset_at_ms,
          resume_at_ms: resume_at,
          attempts: prior,
          provider_code,
          window_label,
          recovery_ready: false,
        }
      } else {
        entry
      }
    })
  } else {
    self.pending.push({
      session_id,
      encountered_at_ms,
      reset_at_ms,
      resume_at_ms: resume_at,
      attempts: prior,
      provider_code,
      window_label,
      generation: self.generation,
      recovery_ready: false,
    })
  }
  self.publish_resume_status()
  (self.trace)(
    "rate limit on session \{session_id} (code=\{Repr(provider_code)}), encountered_at_ms=\{encountered_at_ms}, reset_at_ms=\{Repr(reset_at_ms)}, resume scheduled at \{resume_at}",
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
      ModelFailed(failure=RateLimited(reset_at_ms~, provider_code~, reason~)),
    ) =>
      self.record_limit(
        scope.session_id.to_string(),
        reset_at_ms,
        provider_code,
        window_label=five_hour_label(reason),
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
    (Some(scope), TurnFailed(_)) => {
      // ModelFailed reaches PipelineHook before the Agent saves the failed
      // transcript. Arm this session only after that save and terminal
      // projection have completed.
      let session_id = scope.session_id.to_string()
      self.pending = self.pending.map(fn(entry) {
        if entry.session_id == session_id {
          { ..entry, recovery_ready: true, }
        } else {
          entry
        }
      })
    }
    (Some(scope), TurnCompleted) => {
      self.attempts.remove(scope.session_id.to_string())
      self.pending = self.pending.filter(fn(entry) {
        entry.session_id != scope.session_id.to_string()
      })
      self.publish_resume_status()
    }
    _ => ()
  }
}

///|
pub impl @posoco.Lifecycle for RateLimitGuard with fn on_shutdown(
  self : RateLimitGuard,
) -> Unit {
  self.stopped = true
  self.cancel_pending()
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
/// Remove and return the entries whose resume time has passed.
fn RateLimitGuard::take_due(
  self : RateLimitGuard,
  now_ms : Int64,
) -> Array[PendingResume] {
  if self.stopped {
    return []
  }
  let due = self.pending.filter(fn(entry) {
    entry.recovery_ready && entry.resume_at_ms <= now_ms
  })
  self.pending = self.pending.filter(fn(entry) {
    !entry.recovery_ready || entry.resume_at_ms > now_ms
  })
  // Republish only when resumes actually fired — the monitor polls every
  // interval and an empty take must not emit a no-op unregister each time.
  if due.length() > 0 {
    self.publish_resume_status()
  }
  due
}

///|
/// Run one scheduled recovery. A fresh quota verdict re-records itself via
/// the hook; every other failure is traced and is not retried.
async fn RateLimitGuard::resume_entry(
  self : RateLimitGuard,
  entry : PendingResume,
) -> Unit {
  if entry.generation != self.generation ||
    self.stopped ||
    !entry.recovery_ready {
    return
  }
  let agent = match self.agent {
    Some(agent) => agent
    None => {
      let message = "rate-limit recovery cannot run for session \{entry.session_id}: no agent bound"
      (self.trace)(message)
      fail(message)
    }
  }
  // The Agent owns a single execution loop (one long-lived Puppet), so
  // recoveries serialize because concurrent turns on one Agent are rejected.
  self.turn_lock.acquire()
  if entry.generation != self.generation || self.stopped {
    self.turn_lock.release()
    return
  }
  self.active_resume_generation = Some(entry.generation)
  let outcome : Result[@posoco.TurnResult, Error] = Ok(
    agent.resume_turn(entry.session_id, continuation=self.resume_note),
  ) catch {
    error => Err(error)
  }
  self.active_resume_generation = None
  self.turn_lock.release()
  match outcome {
    Err(error) if @async.is_cancellation_error(error) => raise error
    _ => ()
  }
  if entry.generation != self.generation || self.stopped {
    return
  }
  match outcome {
    Ok(_) => ()
    Err(error) => {
      let re_recorded = find_pending(self.pending, entry.session_id)
      match re_recorded {
        Some(_) =>
          (self.trace)(
            "rate-limit recovery for session \{entry.session_id} hit another rate limit",
          )
        None => {
          (self.trace)(
            "rate-limit recovery failed without retry for session \{entry.session_id}: \{error}",
          )
          raise error
        }
      }
    }
  }
}

///|
/// Resume every due entry inline.
async fn RateLimitGuard::poll_due(
  self : RateLimitGuard,
  now_ms : Int64,
) -> Unit {
  for entry in self.take_due(now_ms) {
    self.resume_entry(entry)
  }
}

///|
/// Run one resume cycle synchronously. Hosts that already own a periodic
/// loop can drive this instead of `spawn_monitor`.
pub async fn RateLimitGuard::poll(self : RateLimitGuard) -> Unit {
  self.poll_due((self.now_ms)())
}

///|
/// Run until `stop()` or host task cancellation. Recoveries execute inline,
/// so cancelling this monitor also cancels its in-flight recovery.
pub async fn RateLimitGuard::monitor(self : RateLimitGuard) -> Unit {
  while !self.stopped {
    self.poll_due((self.now_ms)())
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
    (self.sleep_ms)(delay) catch {
      err if @async.is_cancellation_error(err) => raise err
      err => {
        (self.trace)("rate-limit monitor sleep failed: \{err}")
        raise err
      }
    }
  }
}

///|
/// Spawn `monitor()` into a host-owned task group.
pub fn[G] RateLimitGuard::spawn_monitor(
  self : RateLimitGuard,
  group : @async.TaskGroup[G],
) -> Unit {
  group.spawn_bg(() => self.monitor())
}
