///|
/// Pure rate-limit domain model. No Posoco, EventBus, task or Fuwaroid types
/// belong here; the runtime is only a serialized owner of this state.

priv struct RecoveryPolicy {
  margin_ms : Int64
  max_attempts : Int
  probe_interval_ms : Int64
  max_probe_interval_ms : Int64
}

///|
priv enum RecoverySchedule {
  Scheduled(Int64)
  Unschedulable
  Exhausted
}

///|
/// Compute the next recovery deadline without performing IO or mutating
/// runtime state.
fn RecoveryPolicy::schedule(
  self : RecoveryPolicy,
  reset_at_ms : Int64?,
  attempt : Int,
  now_ms : Int64,
) -> RecoverySchedule {
  if attempt > self.max_attempts {
    return Exhausted
  }
  match reset_at_ms {
    Some(reset) => Scheduled(reset + self.margin_ms)
    None => {
      if self.probe_interval_ms <= 0L {
        return Unschedulable
      }
      let shift = if attempt - 1 > 4 { 4 } else { attempt - 1 }
      let mut backoff = self.probe_interval_ms << shift
      if self.max_probe_interval_ms > 0L &&
        backoff > self.max_probe_interval_ms {
        backoff = self.max_probe_interval_ms
      }
      Scheduled(now_ms + backoff)
    }
  }
}

///|
/// One pending per-session recovery owned exclusively by RateLimitRuntime.
priv struct RecoveryEntry {
  session_id : String
  encountered_at_ms : Int64
  reset_at_ms : Int64?
  resume_at_ms : Int64
  attempts : Int
  provider_code : String?
  window_label : String?
  mut recovery_ready : Bool
}

///|
/// Stamp carried by every async recovery effect. Epoch invalidation makes
/// late completions structural no-ops.
priv struct RecoveryTicket {
  session_id : String
  epoch : Int
  attempt : Int
} derive(Eq, Debug)


///|
/// Read-only compatibility view for hosts and tests. This is a projection,
/// never an alias to the actor-owned RecoveryEntry array.
pub(all) struct RateLimitPending {
  session_id : String
  encountered_at_ms : Int64
  reset_at_ms : Int64?
  resume_at_ms : Int64
  attempts : Int
  provider_code : String?
} derive(Eq, Debug)

///|
pub extend RateLimitPending with Eq::{equal, not_equal}

///|
pub extend RateLimitPending with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Presentation-neutral status projection.
priv struct RecoveryStatus {
  earliest_resume_at : Int64
  window_label : String?
}

///|
fn recovery_snapshot(pending : Array[RecoveryEntry]) -> Array[RateLimitPending] {
  pending.map(fn(entry) {
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
fn recovery_status(pending : Array[RecoveryEntry]) -> RecoveryStatus? {
  if pending.is_empty() {
    return None
  }
  let mut earliest = pending[0]
  for entry in pending {
    if entry.resume_at_ms < earliest.resume_at_ms {
      earliest = entry
    }
  }
  Some({
    earliest_resume_at: earliest.resume_at_ms,
    window_label: earliest.window_label,
  })
}

///|
fn find_recovery_index(
  pending : Array[RecoveryEntry],
  session_id : String,
) -> Int? {
  for i in 0..<pending.length() {
    if pending[i].session_id == session_id {
      return Some(i)
    }
  }
  None
}
