///|
/// Small in-memory implementation of `HandoffWorkSource` for products that do
/// not already have planner/task state to adapt.
///
/// It is deliberately not a Posoco port or extension. The product owns this
/// value and updates it as work advances; `/handoff create` only snapshots it.
pub struct HandoffWorkState {
  mut work : WorkSnapshot
}

///|
fn copy_work(work : WorkSnapshot) -> WorkSnapshot {
  {
    objective: work.objective,
    done_when: work.done_when.copy(),
    constraints: work.constraints.copy(),
    completed: work.completed.copy(),
    current_work: work.current_work,
    decisions: work.decisions.copy(),
    blockers: work.blockers.copy(),
    next_action: work.next_action,
    queue: work.queue.copy(),
    notes: work.notes.copy(),
    validation_passed: work.validation_passed.copy(),
    validation_failed: work.validation_failed.copy(),
    validation_not_run: work.validation_not_run.copy(),
  }
}

///|
pub fn HandoffWorkState::new(
  initial? : WorkSnapshot = WorkSnapshot::empty(),
) -> HandoffWorkState {
  { work: copy_work(initial) }
}

///|
/// Return a detached snapshot; callers cannot mutate the state's arrays by
/// retaining references from this value.
pub fn HandoffWorkState::snapshot(self : HandoffWorkState) -> WorkSnapshot {
  copy_work(self.work)
}

///|
pub fn HandoffWorkState::replace(
  self : HandoffWorkState,
  work : WorkSnapshot,
) -> Unit {
  self.work = copy_work(work)
}

///|
pub fn HandoffWorkState::clear(self : HandoffWorkState) -> Unit {
  self.work = WorkSnapshot::empty()
}

///|
pub fn HandoffWorkState::set_objective(
  self : HandoffWorkState,
  objective : String,
) -> Unit {
  self.work = {
    ..self.work,
    objective: if objective.length() == 0 { None } else { Some(objective) },
  }
}

///|
pub fn HandoffWorkState::set_current_work(
  self : HandoffWorkState,
  current_work : String,
) -> Unit {
  self.work = {
    ..self.work,
    current_work: if current_work.length() == 0 { None } else { Some(current_work) },
  }
}

///|
pub fn HandoffWorkState::set_next_action(
  self : HandoffWorkState,
  next_action : String,
) -> Unit {
  self.work = {
    ..self.work,
    next_action: if next_action.length() == 0 { None } else { Some(next_action) },
  }
}

///|
fn push_unique(values : Array[String], value : String) -> Unit {
  if value.length() > 0 && !values.contains(value) {
    values.push(value)
  }
}

///|
fn remove_value(values : Array[String], value : String) -> Unit {
  values.retain(item => item != value)
}

///|
pub fn HandoffWorkState::add_done_when(
  self : HandoffWorkState,
  item : String,
) -> Unit {
  push_unique(self.work.done_when, item)
}

///|
pub fn HandoffWorkState::add_constraint(
  self : HandoffWorkState,
  item : String,
) -> Unit {
  push_unique(self.work.constraints, item)
}

///|
pub fn HandoffWorkState::add_decision(
  self : HandoffWorkState,
  item : String,
) -> Unit {
  push_unique(self.work.decisions, item)
}

///|
pub fn HandoffWorkState::add_note(
  self : HandoffWorkState,
  item : String,
) -> Unit {
  push_unique(self.work.notes, item)
}

///|
pub fn HandoffWorkState::add_blocker(
  self : HandoffWorkState,
  item : String,
) -> Unit {
  push_unique(self.work.blockers, item)
}

///|
pub fn HandoffWorkState::resolve_blocker(
  self : HandoffWorkState,
  item : String,
) -> Unit {
  remove_value(self.work.blockers, item)
}

///|
pub fn HandoffWorkState::enqueue(
  self : HandoffWorkState,
  item : String,
) -> Unit {
  push_unique(self.work.queue, item)
}

///|
/// Mark work completed and remove the same item from the pending queue.
pub fn HandoffWorkState::complete(
  self : HandoffWorkState,
  item : String,
) -> Unit {
  remove_value(self.work.queue, item)
  push_unique(self.work.completed, item)
}

///|
fn clear_validation(self : HandoffWorkState, check : String) -> Unit {
  remove_value(self.work.validation_passed, check)
  remove_value(self.work.validation_failed, check)
  remove_value(self.work.validation_not_run, check)
}

///|
/// Record one validation check in exactly one bucket. Re-recording the same
/// check moves it between buckets rather than leaving contradictory state.
pub fn HandoffWorkState::validation_passed(
  self : HandoffWorkState,
  check : String,
) -> Unit {
  self.clear_validation(check)
  push_unique(self.work.validation_passed, check)
}

///|
pub fn HandoffWorkState::validation_failed(
  self : HandoffWorkState,
  check : String,
) -> Unit {
  self.clear_validation(check)
  push_unique(self.work.validation_failed, check)
}

///|
pub fn HandoffWorkState::validation_not_run(
  self : HandoffWorkState,
  check : String,
) -> Unit {
  self.clear_validation(check)
  push_unique(self.work.validation_not_run, check)
}

///|
pub impl HandoffWorkSource for HandoffWorkState with fn handoff_work(
  self : HandoffWorkState,
) -> WorkSnapshot {
  self.snapshot()
}
