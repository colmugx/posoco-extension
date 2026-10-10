///|
pub fn lanes() -> Array[@client.ClientBoardStage] {
  [Created, Refining, Ready, Running, Review, Done, Suspended]
}

///|
pub fn stage_label(stage : @client.ClientBoardStage) -> String {
  match stage {
    Created => "Created"
    Refining => "Refining"
    Ready => "Ready"
    Running => "Running"
    Review => "Review"
    Done => "Done"
    Suspended => "Suspended"
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
/// Move suggestions are a UX convenience mirroring the Board v1 stage FSM;
/// the durable server stays authoritative and may still reject a move. The
/// table covers every stage so the view can render a control row for any
/// card.
pub fn move_suggestions(
  stage : @client.ClientBoardStage,
) -> Array[@client.ClientBoardStage] {
  match stage {
    Created => [Refining, Suspended]
    Refining => [Ready, Suspended]
    Ready => [Running, Refining, Suspended]
    Running => [Review, Suspended]
    Review => [Done, Ready, Refining, Suspended]
    Done => [Refining]
    Suspended => [Created, Refining, Ready]
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
) -> Int {
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
fn visible_lane_tasks(
  replica : @client.BoardReplica,
  stage : @client.ClientBoardStage,
  filter : TaskFilter,
) -> Array[@client.ClientBoardTask] {
  visible_tasks(replica, filter).filter(task => task.stage == stage)
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
fn lane_count_summary(
  replica : @client.BoardReplica,
  stage : @client.ClientBoardStage,
  filter : TaskFilter,
) -> String {
  let total = tasks_in_lane(replica, stage).length()
  if task_filter_active(filter) {
    "\{visible_lane_tasks(replica, stage, filter).length()} of \{total}"
  } else {
    "\{total}"
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
/// it is the only state the user can act on; otherwise the connection and
/// baseline transitions own the text.
fn status_text(model : Model) -> String {
  if model.pending is Some(_) {
    "Saving change; waiting for authoritative confirmation."
  } else {
    model.last_status
  }
}

///|
pub fn attempt_count(replica : @client.BoardReplica, task_id : String) -> Int {
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
