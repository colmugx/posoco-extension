///|
/// Batch policy layer over the Agent-owned task capability: the kit plans
/// and projects, core executes. One `BatchItem` describes a single already
/// resolved child request — every slicing decision (kind, slot/effort, tool
/// face, permission) is made before a plan exists, so the batch layer never
/// re-derives configuration and never starts work.
pub(all) struct BatchItem {
  /// Domain key identifying this item inside the batch (usually the child
  /// session id); unique within one plan.
  key : String
  /// Child transcript session (resume key / receipt label).
  child_session_id : String
  /// Task text for the child's user-position slot.
  task : String
  /// Resolved kind name.
  kind_name : String
  /// Resolved model slot and reasoning effort.
  selection : ResolvedSelection
  /// Resolved tool face (spawn whitelist ∩ kind whitelist).
  tools : Array[String]
  /// Permission posture the child runs with.
  permission : @permission.PermissionMode
  /// Execution lifetime the coordinator requests from the Agent.
  mode : @posoco.TaskMode
  /// Per-item timeout in milliseconds (positive).
  timeout_ms : Int
  /// True when continuing an existing child session.
  resuming : Bool
} derive(Eq, @debug.Debug)

///|
/// Batch planning failures; messages are model-facing.
pub(all) suberror BatchPlanError {
  ItemsEmpty
  TooManyItems(limit~ : Int)
  DuplicateKey(key~ : String)
  InvalidTimeout(key~ : String)
} derive(Eq, @debug.Debug)

///|
/// A batch as pure plan: ordered items plus the wave cap derived from
/// `SubagentLimits.concurrency`. Building a plan validates; it never submits.
pub(all) struct BatchPlan {
  items : Array[BatchItem]
  /// Maximum concurrently admitted items (>= 1).
  wave_cap : Int
} derive(@debug.Debug)

///|
/// Build a plan from resolved items under the config's limits. Refuses
/// empty batches, batches above `swarm_items`, duplicate keys, and
/// non-positive timeouts — the caller rejects explicitly, nothing queues.
pub fn BatchPlan::build(
  config~ : SubagentConfig,
  items~ : Array[BatchItem],
) -> BatchPlan raise BatchPlanError {
  if items.is_empty() {
    raise BatchPlanError::ItemsEmpty
  }
  if items.length() > config.limits.swarm_items {
    raise BatchPlanError::TooManyItems(limit=config.limits.swarm_items)
  }
  let seen : Set[String] = Set([])
  for item in items {
    if seen.contains(item.key) {
      raise BatchPlanError::DuplicateKey(key=item.key)
    }
    seen.add(item.key)
    if item.timeout_ms <= 0 {
      raise BatchPlanError::InvalidTimeout(key=item.key)
    }
  }
  let wave_cap = if config.limits.concurrency < 1 {
    1
  } else {
    config.limits.concurrency
  }
  { items, wave_cap, }
}

///|
/// Domain projection of one admitted item: the receipt the Agent minted is
/// kept only as a key→receipt-id mapping; handles themselves stay with the
/// coordinator that will `wait` on them.
pub(all) struct BatchState {
  /// Item keys still without a terminal, in admission order.
  mut pending : Array[String]
  /// Receipt id → item key for every accepted item.
  mut receipts : Map[String, String]
  /// Item key → terminal classification once observed.
  mut terminals : Map[String, TerminalState]
} derive(@debug.Debug)

///|
/// Fresh state for a plan: every key pending, nothing accepted.
pub fn BatchState::BatchState(plan~ : BatchPlan) -> BatchState {
  let pending : Array[String] = []
  for item in plan.items {
    pending.push(item.key)
  }
  { pending, receipts: Map::from_array([]), terminals: Map::from_array([]), }
}

///|
/// Record an accepted submission: maps the Agent receipt id to the item key
/// the coordinator submitted it for.
pub fn BatchState::on_accepted(
  self : BatchState,
  key~ : String,
  receipt~ : @posoco.TaskReceipt,
) -> Unit {
  match self.receipts.get(receipt.id) {
    Some(_) => ()
    None => self.receipts[receipt.id] = key
  }
}

///|
/// Record one terminal outcome: the receipt id resolves back to the item
/// key, the status maps to the kit's terminal classification, and the key
/// leaves the pending set. Unknown receipt ids are ignored — outcomes the
/// coordinator did not submit are core's business, not this projection's.
pub fn BatchState::on_outcome(
  self : BatchState,
  outcome~ : @posoco.TaskOutcome,
) -> Unit {
  let key = match self.receipts.get(outcome.receipt.id) {
    Some(key) => key
    None => return
  }
  if !self.terminals.contains(key) {
    self.terminals[key] = task_status_to_terminal(status=outcome.status)
    let kept : Array[String] = []
    for candidate in self.pending {
      if candidate != key {
        kept.push(candidate)
      }
    }
    self.pending = kept
  }
}

///|
/// True once every planned key has a terminal.
pub fn BatchState::is_settled(self : BatchState) -> Bool {
  self.pending.is_empty()
}

///|
/// Terminal batch projection: per-key terminals plus aggregated counts and
/// a one-line-per-item summary text. Built from observed outcomes only —
/// it re-interprets nothing about core cancellation.
pub(all) struct BatchResult {
  terminals : Map[String, TerminalState]
  completed : Int
  failed : Int
  timed_out : Int
  cancelled : Int
} derive(@debug.Debug)

///|
/// Snapshot the current state as a result.
pub fn BatchState::result(self : BatchState) -> BatchResult {
  let terminals : Map[String, TerminalState] = Map::from_array([])
  let mut completed = 0
  let mut failed = 0
  let mut timed_out = 0
  let mut cancelled = 0
  for key, state in self.terminals {
    terminals[key] = state
    match state {
      Completed => completed = completed + 1
      Failed(_) => failed = failed + 1
      TimedOut => timed_out = timed_out + 1
      Cancelled => cancelled = cancelled + 1
    }
  }
  { terminals, completed, failed, timed_out, cancelled, }
}

///|
/// Aggregated summary text: one line per settled item plus a totals line.
pub fn BatchResult::summary(self : BatchResult) -> String {
  let lines : Array[String] = []
  for key, state in self.terminals {
    match state {
      Completed => lines.push("\{key}: completed")
      Failed(reason~) => lines.push("\{key}: failed: \{reason}")
      TimedOut => lines.push("\{key}: timed out")
      Cancelled => lines.push("\{key}: cancelled")
    }
  }
  lines.push(
    "total: \{self.completed} completed, \{self.failed} failed, \{self.timed_out} timed out, \{self.cancelled} cancelled",
  )
  lines.join("\n")
}

///|
/// Map the Agent's terminal task status onto the kit's terminal
/// classification (design §2.1): statuses correspond one-to-one; the
/// message payload of `Completed` is not re-interpreted here.
pub fn task_status_to_terminal(status~ : @posoco.TaskStatus) -> TerminalState {
  match status {
    @posoco.TaskStatus::Completed(..) => Completed
    @posoco.TaskStatus::Failed(reason~) => Failed(reason~)
    @posoco.TaskStatus::TimedOut => TimedOut
    @posoco.TaskStatus::Cancelled(..) => Cancelled
  }
}

///|
/// State word for a terminal classification, matching the structured
/// payload vocabulary of `terminal_outcome`.
pub fn terminal_state_word(state : TerminalState) -> String {
  match state {
    Completed => "completed"
    Failed(_) => "failed"
    TimedOut => "timed_out"
    Cancelled => "cancelled"
  }
}
