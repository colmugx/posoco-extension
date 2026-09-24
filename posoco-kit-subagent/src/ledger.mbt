///|
/// Per-run spawn budget ledger (design §6.3): counts spawns across the
/// `agent` and `agent_swarm` tools of one run and refuses once the budget is
/// exhausted — the caller rejects explicitly, nothing queues silently.
/// Counting only in v1 (a concurrency semaphore belongs to the ext-swarm
/// wave); acquisition is monotonic — there is no release, and duplicate
/// labels are recorded as separate acquisitions for audit.
pub(all) struct SpawnLedger {
  /// Maximum acquisitions; `remaining` reaches 0 here.
  limit : Int
  /// Acquisition-ordered audit record; duplicate labels appear once per
  /// acquire.
  labels : Array[String]
} derive(@debug.Debug)

///|
pub extend SpawnLedger with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Fresh ledger with the given spawn budget (default: the §9.2 value 64).
pub fn SpawnLedger::SpawnLedger(limit? : Int = 64) -> SpawnLedger {
  { limit, labels: [], }
}

///|
/// Try to spend one unit of the budget under `label`. True records the
/// acquisition; false means the budget is exhausted and the caller must
/// reject the spawn explicitly.
pub fn SpawnLedger::try_acquire(self : SpawnLedger, label : String) -> Bool {
  if self.labels.length() >= self.limit {
    return false
  }
  self.labels.push(label)
  true
}

///|
/// Copy of the acquired labels in acquisition order (duplicates preserved).
pub fn SpawnLedger::acquired(self : SpawnLedger) -> Array[String] {
  let out : Array[String] = []
  for label in self.labels {
    out.push(label)
  }
  out
}

///|
/// Units still available before `try_acquire` starts refusing.
pub fn SpawnLedger::remaining(self : SpawnLedger) -> Int {
  self.limit - self.labels.length()
}

///|
/// Reset the per-run budget at the next run boundary while preserving the
/// configured limit.
pub fn SpawnLedger::reset(self : SpawnLedger) -> Unit {
  self.labels.clear()
}
