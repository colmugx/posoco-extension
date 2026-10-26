///|
pub fn lanes() -> Array[@client.ClientBoardStage] {
  [Created, Refining, Ready, Running, Verification, Review, Done, Suspended, Cancelled]
}

///|
/// The flow stages; Done, Suspended and Cancelled are archive states.
pub fn flow_lanes() -> Array[@client.ClientBoardStage] {
  [Created, Refining, Ready, Running, Verification, Review]
}

///|
pub fn archive_lanes() -> Array[@client.ClientBoardStage] {
  [Done, Suspended, Cancelled]
}

///|
/// Working vocabulary for the board surface. The wire/domain labels stay
/// available through `stage_label`; the UI says what a person does, not what
/// the enum is called.
pub fn ui_stage_label(stage : @client.ClientBoardStage) -> String {
  match stage {
    Created => "Backlog"
    Refining => "Shaping"
    Ready => "Ready"
    Running => "In progress"
    Verification => "Verification"
    Review => "In review"
    Done => "Done"
    Suspended => "Paused"
    Cancelled => "Cancelled"
  }
}

///|
/// One-line meaning of each flow stage, used under the lane title so the
/// pipeline explains itself instead of relying on enum trivia.
pub fn stage_hint(stage : @client.ClientBoardStage) -> String {
  match stage {
    Created => "A rough idea. Shape it before anyone can start."
    Refining => "An agent or a person clarifies scope and acceptance."
    Ready => "Scoped and waiting for a worker."
    Running => "Work in progress."
    Verification => "Independent verification against the story."
    Review => "Check the result, record a decision, then close it."
    Done => "Closed."
    Suspended => "Parked without losing its history."
    Cancelled => "Superseded or abandoned; kept for history."
  }
}

///|
/// One-based pipeline position. Archive stages sit outside the flow.
pub fn stage_step(stage : @client.ClientBoardStage) -> Int32? {
  match stage {
    Created => Some(1)
    Refining => Some(2)
    Ready => Some(3)
    Running => Some(4)
    Verification => Some(5)
    Review => Some(6)
    Done | Suspended | Cancelled => None
  }
}

///|
/// A pipeline step is offered only when the v1 FSM allows that move.
pub fn step_reachable(
  from : @client.ClientBoardStage,
  to : @client.ClientBoardStage,
) -> Bool {
  move_suggestions(from).contains(to)
}

///|
/// Grammar-safe dependency count for the card meta row.
pub fn dependency_count_label(count : Int32) -> String {
  if count == 1 {
    "1 dep"
  } else {
    "\{count} deps"
  }
}

///|
/// The last segment of the pipeline, used to label the closing step.
pub fn done_stage() -> @client.ClientBoardStage {
  Done
}

///|
/// The forward transition for a stage. This is the card's primary intent; the
/// remaining legal transitions live in the card menu. Cancelled is terminal,
/// so it maps to itself: no view ever renders a primary action for it.
pub fn primary_move(
  stage : @client.ClientBoardStage,
) -> @client.ClientBoardStage {
  match stage {
    Created => Refining
    Refining => Ready
    Ready => Running
    Running => Verification
    Verification => Review
    Review => Done
    Done => Refining
    Suspended => Ready
    Cancelled => Cancelled
  }
}

///|
/// The label of the primary intent. A cancelled task has no next stage, so
/// its label is the terminal word itself and never a command.
pub fn primary_action_label(stage : @client.ClientBoardStage) -> String {
  match stage {
    Created => "Start shaping"
    Refining => "Mark ready"
    Ready => "Start work"
    Running => "Send to verification"
    Verification => "Request review"
    Review => "Mark done"
    Done => "Reopen"
    Suspended => "Resume"
    Cancelled => "Cancelled"
  }
}

///|
/// Compact priority marker for scanned cards. This is deliberately a short
/// ordinal, not a pill badge.
pub fn priority_short(priority : @client.ClientBoardPriority) -> String {
  match priority {
    Low => "P3"
    Normal => "P2"
    High => "P1"
    Critical => "P0"
  }
}

///|
pub fn priority_tone(priority : @client.ClientBoardPriority) -> String {
  match priority {
    Low => "low"
    Normal => "normal"
    High => "high"
    Critical => "critical"
  }
}

///|
/// One-word attempt state for the card meta row. The inspector keeps the full
/// vocabulary; the board only needs enough to scan.
pub fn attempt_short(
  replica : @client.BoardReplica,
  task_id : String,
) -> String {
  let attempts = replica
    .attempts()
    .filter(attempt => attempt.task_id == task_id)
  if attempts.any(attempt => attempt.status is Running) {
    return "running"
  }
  match latest_attempt(attempts) {
    None => "no runs"
    Some(attempt) => "last \{attempt_status_short(attempt.status)}"
  }
}

///|
fn attempt_status_short(status : @client.ClientAttemptStatus) -> String {
  match status {
    Queued => "queued"
    Running => "running"
    Succeeded => "succeeded"
    Failed => "failed"
    Cancelled => "cancelled"
    Interrupted => "interrupted"
  }
}

///|
pub fn stage_label(stage : @client.ClientBoardStage) -> String {
  match stage {
    Created => "Created"
    Refining => "Refining"
    Ready => "Ready"
    Running => "Running"
    Verification => "Verification"
    Review => "Review"
    Done => "Done"
    Suspended => "Suspended"
    Cancelled => "Cancelled"
  }
}

///|
pub fn priority_label(priority : @client.ClientBoardPriority) -> String {
  match priority {
    Low => "Low"
    Normal => "Normal"
    High => "High"
    Critical => "Critical"
  }
}

///|
/// Fixed option order for the editor priority select. Wire spelling always
/// comes from the client's centralized `to_wire`, never from this package.
pub fn priorities() -> Array[@client.ClientBoardPriority] {
  [Low, Normal, High, Critical]
}

///|
/// Fixed option order for the queue-attempt kind select.
pub fn attempt_kinds() -> Array[@client.ClientAttemptKind] {
  [Discuss, Execute, Review]
}

///|
/// Fixed option order for the finish-attempt outcome select; every entry is
/// an explicit terminal choice the user must see before finishing.
pub fn attempt_outcomes() -> Array[@client.ClientAttemptOutcome] {
  [Succeeded, Failed, Cancelled, Interrupted]
}

///|
/// Fixed option order for the record-review decision select. Pending is
/// deliberately absent: it is the implicit state while a review attempt
/// runs, so only the two terminal decisions can be recorded.
pub fn review_decisions() -> Array[@client.ClientRecordableReviewDecision] {
  [Approved, ChangesRequested]
}

///|
pub fn review_decision_label(
  decision : @client.ClientRecordableReviewDecision,
) -> String {
  match decision {
    Approved => "Approve"
    ChangesRequested => "Request changes"
  }
}

///|
/// Live eligibility for recording a review decision, mirroring the domain
/// window exactly: only a Review attempt that is Running and still Pending
/// accepts a decision. Recording never changes the attempt status.
pub fn review_recordable(attempt : @client.ClientAttempt) -> Bool {
  attempt.kind is Review &&
  attempt.status is Running &&
  attempt.review is Some(Pending)
}

///|
/// A Running Review attempt without a recorded decision warns on Finish but
/// never blocks it: recording stays a separate explicit command.
pub fn finish_review_pending(attempt : @client.ClientAttempt) -> Bool {
  attempt.status is Running &&
  attempt.kind is Review &&
  attempt.review is Some(Pending)
}

///|
pub fn outcome_label(outcome : @client.ClientAttemptOutcome) -> String {
  match outcome {
    Succeeded => "Succeeded"
    Failed => "Failed"
    Cancelled => "Cancelled"
    Interrupted => "Interrupted"
  }
}

///|
/// Live status validation: only a queued attempt offers manual start.
pub fn attempt_startable(status : @client.ClientAttemptStatus) -> Bool {
  status is Queued
}

///|
/// Live status validation: only a running attempt offers manual finish, and
/// finishing always requires an explicit terminal outcome choice.
pub fn attempt_finishable(status : @client.ClientAttemptStatus) -> Bool {
  status is Running
}

///|
/// Live attempt-ID draft validation against the authoritative replica: the
/// trimmed identifier must be non-empty and unused by any attempt. This is
/// a UX convenience only; the durable server owns duplicates and existence.
pub fn queue_attempt_id_valid(
  replica : @client.BoardReplica,
  raw_id : String,
) -> Bool {
  let id = raw_id.trim().to_owned()
  replica.has_snapshot() &&
  id != "" &&
  !replica.attempts().any(attempt => attempt.id == id)
}

///|
/// A work item may enter Ready only after a Refiner has written the full
/// story contract. Backlog and Shaping are intentionally not gated.
pub fn ready_blocked_hint(
  task : @client.ClientBoardTask,
) -> String? {
  if task.user_story.trim().is_empty() {
    Some("A Refiner must add the user story before this can be Ready.")
  } else if task.description.trim().is_empty() {
    Some("The story needs a detailed description before it can be Ready.")
  } else if task.implementation_suggestions.trim().is_empty() {
    Some("The story needs implementation suggestions before it can be Ready.")
  } else if task.definition_of_done.is_empty() {
    Some("The story needs at least one definition-of-done item.")
  } else {
    None
  }
}

///|
/// Move suggestions are a UX convenience mirroring the Board stage FSM;
/// the durable server stays authoritative and may still reject a move.
pub fn move_suggestions(
  stage : @client.ClientBoardStage,
) -> Array[@client.ClientBoardStage] {
  match stage {
    Created => [Refining, Suspended, Cancelled]
    Refining => [Ready, Suspended, Cancelled]
    Ready => [Running, Refining, Suspended, Cancelled]
    Running => [Verification, Suspended, Cancelled]
    Verification => [Review, Ready, Refining, Suspended, Cancelled]
    Review => [Done, Ready, Refining, Suspended, Cancelled]
    Done => [Refining]
    Suspended => [Created, Refining, Ready, Cancelled]
    Cancelled => []
  }
}

///|
/// Split a definition-of-done draft into entries: one entry per line with
/// surrounding whitespace dropped and empty lines removed.
pub fn definition_of_done_lines(text : String) -> Array[String] {
  text
  .split("\n")
  .map(line => line.trim().to_owned())
  .filter(line => line != "")
  .collect()
}

///|
/// Join definition-of-done entries back into the multi-line editor draft.
pub fn definition_of_done_text(lines : Array[String]) -> String {
  lines.join("\n")
}

///|
pub fn tasks_in_lane(
  replica : @client.BoardReplica,
  stage : @client.ClientBoardStage,
) -> Array[@client.ClientBoardTask] {
  replica.tasks().filter(task => task.stage == stage)
}

///|
/// Deterministic attempt order: created_at_ms ascending with the ID as the
/// tie-break, shared by the inspector history and the card indicator.
fn attempt_order(
  left : @client.ClientAttempt,
  right : @client.ClientAttempt,
) -> Int32 {
  let created = left.created_at_ms.compare(right.created_at_ms)
  if created == 0 {
    left.id.compare(right.id)
  } else {
    created
  }
}

///|
/// The replica's tasks in deterministic created_at_ms ascending order with
/// the ID as the tie-break; the replica's own array is detached, so sorting
/// it never leaks into a previous model.
///
/// ```mbt check
/// test {
///   assert_eq(@src.ordered_tasks(@client.BoardReplica::empty()).length(), 0)
/// }
/// ```
pub fn ordered_tasks(
  replica : @client.BoardReplica,
) -> Array[@client.ClientBoardTask] {
  let tasks = replica.tasks()
  tasks.sort_by((left, right) => {
    let created = left.created_at_ms.compare(right.created_at_ms)
    if created == 0 {
      left.id.compare(right.id)
    } else {
      created
    }
  })
  tasks
}

///|
fn task_filter_active(filter : TaskFilter) -> Bool {
  filter.query.trim() != "" ||
  filter.priority is Some(_) ||
  filter.stage is Some(_)
}

///|
/// Browser `String.prototype.toLowerCase`. MoonBit's `to_lower` converts
/// ASCII only; this module is JS-only, so one tiny FFI keeps title, ID and
/// description matching case-insensitive for Unicode text without a new
/// dependency.
extern "js" fn lowercased(value : String) -> String =
  #|value => value.toLowerCase()

///|
/// Case-insensitive substring match over title, ID and description, combined
/// with exact priority and stage choices. A blank query matches everything.
fn task_matches_filter(
  task : @client.ClientBoardTask,
  filter : TaskFilter,
) -> Bool {
  let query = lowercased(filter.query.trim().to_owned())
  if query != "" &&
    !lowercased(task.title).contains(query) &&
    !lowercased(task.id).contains(query) &&
    !lowercased(task.description).contains(query) {
    return false
  }
  match filter.priority {
    Some(priority) if task.priority != priority => return false
    _ => ()
  }
  match filter.stage {
    Some(stage) if task.stage != stage => return false
    _ => ()
  }
  true
}

///|
/// Visible tasks: the deterministic created order with every filter applied.
fn visible_tasks(
  replica : @client.BoardReplica,
  filter : TaskFilter,
) -> Array[@client.ClientBoardTask] {
  ordered_tasks(replica).filter(task => task_matches_filter(task, filter))
}

///|
/// The stage a task renders at: an in-flight move shows its target stage
/// while the authoritative record still holds the origin.
fn staged_stage(
  task : @client.ClientBoardTask,
  optimistic : OptimisticMove?,
) -> @client.ClientBoardStage {
  match optimistic {
    Some(pending_move) if pending_move.task_id == task.id => pending_move.to
    _ => task.stage
  }
}

///|
/// Whether one pending command visibly belongs to a task. Moves, edits,
/// dependency saves and attempt queues name their task directly; attempt
/// start/finish/review surface their in-flight state in the inspector
/// instead of on the card.
fn pending_for_task(pending : PendingCommand?, task_id : String) -> Bool {
  match pending {
    None => false
    Some(pending) => pending_task_id(pending.kind) == task_id
  }
}

///|
/// The task a pending command visibly belongs to; attempt start/finish/review
/// only name their attempt and stay in the inspector instead.
fn pending_task_id(kind : PendingKind) -> String {
  match kind {
    PendingCreate => ""
    PendingEdit(task_id~)
    | PendingDependencies(task_id~)
    | PendingMove(task_id~, ..)
    | PendingAttemptQueue(task_id~, ..) => task_id
    PendingAttemptStart(_) | PendingAttemptFinish(_) | PendingReview(_) => ""
  }
}

///|
/// Wall-clock relative label: "just now", minutes, hours, then days, after
/// which the caller keeps the absolute UTC stamp. Pure so tests can pin it.
pub fn relative_at(at_ms : Int64, now_ms : Int64) -> String {
  let delta = now_ms - at_ms
  if delta < 0L {
    return utc_timestamp(at_ms)
  }
  let minutes = delta / 60000L
  if minutes < 1L {
    "just now"
  } else if minutes < 60L {
    "\{minutes}m ago"
  } else {
    let hours = minutes / 60L
    if hours < 24L {
      "\{hours}h ago"
    } else {
      let days = hours / 24L
      if days < 30L {
        "\{days}d ago"
      } else {
        utc_timestamp(at_ms)
      }
    }
  }
}

///|
/// True only when an authoritative board has tasks but the active filter
/// hides them all — distinct from an unknown board and an empty board.
fn filters_hide_all(
  replica : @client.BoardReplica,
  filter : TaskFilter,
) -> Bool {
  replica.has_snapshot() &&
  !replica.tasks().is_empty() &&
  task_filter_active(filter) &&
  visible_tasks(replica, filter).is_empty()
}

///|
fn task_count_summary(
  replica : @client.BoardReplica,
  filter : TaskFilter,
) -> String {
  let total = replica.tasks().length()
  if task_filter_active(filter) {
    "\{visible_tasks(replica, filter).length()} of \{total} tasks"
  } else {
    "\{total} tasks"
  }
}

///|
/// The lane head count: shown tasks at the staged stage, with the
/// `visible of total` form while a filter is active.
fn lane_count_label(
  replica : @client.BoardReplica,
  visible : Array[@client.ClientBoardTask],
  stage : @client.ClientBoardStage,
  optimistic : OptimisticMove?,
  filter : TaskFilter,
) -> String {
  let shown = visible
    .filter(task => staged_stage(task, optimistic) == stage)
    .length()
  if task_filter_active(filter) {
    "\{shown} of \{tasks_in_lane(replica, stage).length()}"
  } else {
    "\{shown}"
  }
}

///|
/// Resolve a filter select value to a priority: the empty value clears,
/// unknown values keep the current choice.
fn filter_priority_from_wire(
  value : String,
  current : @client.ClientBoardPriority?,
) -> @client.ClientBoardPriority? {
  if value == "" {
    None
  } else {
    match priority_from_wire(value) {
      Some(priority) => Some(priority)
      None => current
    }
  }
}

///|
/// Resolve a filter select value to a stage: the empty value clears, unknown
/// values keep the current choice.
fn filter_stage_from_wire(
  value : String,
  current : @client.ClientBoardStage?,
) -> @client.ClientBoardStage? {
  if value == "" {
    None
  } else {
    match lanes().filter(stage => stage.to_wire() == value).get(0) {
      Some(stage) => Some(stage)
      None => current
    }
  }
}

///|
/// The header status line. An in-flight command outranks everything because
/// it is the only state the user can act on; the stale veil follows, then the
/// connection and baseline transitions own the text.
fn status_text(model : Model) -> String {
  if model.pending is Some(_) {
    "Saving change; waiting for authoritative confirmation."
  } else if model.stale {
    "The board is out of date. Reconnecting for fresh state."
  } else {
    model.last_status
  }
}

///|
/// The next/previous visible task in flow order, honouring the current
/// filters and an in-flight move's target lane. `J` with nothing selected
/// picks the first card, `K` the last; the ends do not wrap.
fn adjacent_task(model : Model, step : Int32) -> String? {
  let visible = visible_tasks(model.replica, model.task_filter)
  let order : Array[String] = []
  for stage in flow_lanes() {
    for task in visible {
      if staged_stage(task, model.optimistic) == stage {
        order.push(task.id)
      }
    }
  }
  guard order.length() > 0 else { return None }
  let mut current = -1
  for i, id_in_order in order {
    if model.selected_task == Some(id_in_order) {
      current = i
      break
    }
  }
  if current < 0 {
    if step > 0 {
      Some(order[0])
    } else {
      Some(order[order.length() - 1])
    }
  } else {
    let next = current + step
    if next >= 0 && next < order.length() {
      Some(order[next])
    } else {
      None
    }
  }
}

///|
pub fn attempt_count(replica : @client.BoardReplica, task_id : String) -> Int32 {
  replica.attempts().filter(attempt => attempt.task_id == task_id).length()
}

///|
/// The card's attempt summary never shows a naked status word: "Running"
/// would read as the task's stage or an Agent run, so a running attempt says
/// so explicitly and any other state is prefixed as the latest attempt. The
/// latest attempt is the last in the deterministic created order with the ID
/// tie-break; a running attempt on the task always outranks it.
pub fn attempt_indicator(
  replica : @client.BoardReplica,
  task_id : String,
) -> String {
  let attempts = replica
    .attempts()
    .filter(attempt => attempt.task_id == task_id)
  if attempts.any(attempt => attempt.status is Running) {
    return "Attempt: Running (manual)"
  }
  match latest_attempt(attempts) {
    None => "No attempts"
    Some(attempt) => "Latest attempt: \{attempt_status_label(attempt.status)}"
  }
}

///|
/// Last entry of the deterministic created order: greatest created_at_ms,
/// greatest ID on ties.
fn latest_attempt(
  attempts : Array[@client.ClientAttempt],
) -> @client.ClientAttempt? {
  if attempts.is_empty() {
    return None
  }
  attempts.sort_by(attempt_order)
  attempts.get(attempts.length() - 1)
}

///|
/// Loading and empty are distinct: without an authoritative snapshot the
/// board is unknown, not empty. Invalidation clears the records, so no
/// stale cards survive a resync.
pub fn empty_message(replica : @client.BoardReplica) -> String? {
  if !replica.has_snapshot() {
    Some("Waiting for Board state")
  } else if replica.tasks().is_empty() {
    Some("No Board tasks yet")
  } else {
    None
  }
}
