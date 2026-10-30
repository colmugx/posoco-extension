///|
/// Encapsulated board state. Revision starts at 0 and advances by exactly
/// one per accepted mutation. Only `BoardDomain::propose` in this package
/// produces successor states; every query returns deep copies, so callers
/// can never alias or mutate committed state.
pub struct BoardState {
  priv mut revision : Int64
  priv tasks : Map[BoardTaskId, BoardTask]
  priv attempts : Map[AttemptId, Attempt]
  priv expansions : Map[ExpansionId, ExpansionRecord]
}

///|
pub fn BoardState::BoardState() -> BoardState {
  {
    revision: 0L,
    tasks: Map::from_array([]),
    attempts: Map::from_array([]),
    expansions: Map::from_array([]),
  }
}

///|
pub fn BoardState::revision(self : BoardState) -> Int64 {
  self.revision
}

///|
/// Detached copy of one task, or None when absent.
pub fn BoardState::task(self : BoardState, id : BoardTaskId) -> BoardTask? {
  self.tasks.get(id).map(task => task.copy_detached())
}

///|
/// Package-internal lookup without copying; never exposed to callers.
fn BoardState::task_ref(self : BoardState, id : BoardTaskId) -> BoardTask? {
  self.tasks.get(id)
}

///|
/// All tasks in deterministic order: priority descending, then creation
/// time ascending, then id ascending.
pub fn BoardState::tasks(self : BoardState) -> Array[BoardTask] {
  let all = self.tasks.values().map(task => task.copy_detached()).collect()
  all.sort_by(compare_task_order)
  all
}

///|
/// Detached copy of one attempt, or None when absent.
pub fn BoardState::attempt(self : BoardState, id : AttemptId) -> Attempt? {
  self.attempts.get(id).map(attempt => attempt.copy_detached())
}

///|
/// All attempts in deterministic order: creation time ascending, then id
/// ascending.
pub fn BoardState::attempts(self : BoardState) -> Array[Attempt] {
  let all = self.attempts
    .values()
    .map(attempt => attempt.copy_detached())
    .collect()
  all.sort_by(compare_attempt_order)
  all
}

///|
/// Detached copy of one durable expansion record, or None when the
/// expansion id is not part of the committed history.
pub fn BoardState::expansion(
  self : BoardState,
  id : ExpansionId,
) -> ExpansionRecord? {
  self.expansions.get(id).map(record => record.copy_detached())
}

///|
/// All durable expansion records in deterministic order: creation time
/// ascending, then expansion id ascending.
pub fn BoardState::expansions(self : BoardState) -> Array[ExpansionRecord] {
  let all = self.expansions
    .values()
    .map(record => record.copy_detached())
    .collect()
  all.sort_by(compare_expansion_order)
  all
}

///|
pub fn BoardState::snapshot(self : BoardState) -> BoardStateSnapshot {
  {
    revision: self.revision,
    tasks: self.tasks(),
    attempts: self.attempts(),
    expansions: self.expansions(),
  }
}

///|
fn BoardState::put_task(self : BoardState, task : BoardTask) -> Unit {
  self.tasks[task.id] = task
}

///|
fn BoardState::remove_task(self : BoardState, id : BoardTaskId) -> Unit {
  self.tasks.remove(id)
}

///|
fn BoardState::put_attempt(self : BoardState, attempt : Attempt) -> Unit {
  self.attempts[attempt.id] = attempt
}

///|
fn BoardState::put_expansion(
  self : BoardState,
  record : ExpansionRecord,
) -> Unit {
  self.expansions[record.expansion_id] = record
}

///|
fn BoardState::bump_revision(self : BoardState) -> Unit {
  self.revision = self.revision + 1L
}
