///|
/// Encapsulated board state. Revision starts at 0 and advances by exactly
/// one per accepted mutation. Only `BoardDomain::propose` in this package
/// produces successor states; every query returns deep copies, so callers
/// can never alias or mutate committed state.
pub struct BoardState {
  priv mut revision : Int64
  priv tasks : Map[BoardTaskId, BoardTask]
  priv attempts : Map[AttemptId, Attempt]
}

///|
pub fn BoardState::BoardState() -> BoardState {
  { revision: 0L, tasks: Map::from_array([]), attempts: Map::from_array([]), }
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
pub fn BoardState::snapshot(self : BoardState) -> BoardStateSnapshot {
  { revision: self.revision, tasks: self.tasks(), attempts: self.attempts(), }
}

///|
/// Deterministic listing order; ids make the order total.
fn compare_task_order(a : BoardTask, b : BoardTask) -> Int {
  let rank = b.priority.rank() - a.priority.rank()
  if rank != 0 {
    return rank
  }
  if a.created_at_ms != b.created_at_ms {
    return if a.created_at_ms < b.created_at_ms { -1 } else { 1 }
  }
  a.id.value.compare(b.id.value)
}

///|
fn compare_attempt_order(a : Attempt, b : Attempt) -> Int {
  if a.created_at_ms != b.created_at_ms {
    return if a.created_at_ms < b.created_at_ms { -1 } else { 1 }
  }
  a.id.value.compare(b.id.value)
}

///|
/// Array-bearing records are always copied, never shared across state
/// boundaries.
pub fn BoardTask::copy_detached(self : BoardTask) -> BoardTask {
  {
    ..self,
    definition_of_done: self.definition_of_done.copy(),
    dependencies: self.dependencies.copy(),
  }
}

///|
pub fn Attempt::copy_detached(self : Attempt) -> Attempt {
  { ..self, }
}

///|
/// Full deep copy: successor states are built from this, so a proposal can
/// never mutate its input state, not even through shared arrays.
fn BoardState::clone_detached(self : BoardState) -> BoardState {
  let tasks : Map[BoardTaskId, BoardTask] = Map::from_array([])
  for id, task in self.tasks {
    tasks[id] = task.copy_detached()
  }
  let attempts : Map[AttemptId, Attempt] = Map::from_array([])
  for id, attempt in self.attempts {
    attempts[id] = attempt.copy_detached()
  }
  { revision: self.revision, tasks, attempts, }
}

///|
fn BoardState::put_task(self : BoardState, task : BoardTask) -> Unit {
  self.tasks[task.id] = task
}

///|
fn BoardState::put_attempt(self : BoardState, attempt : Attempt) -> Unit {
  self.attempts[attempt.id] = attempt
}

///|
fn BoardState::bump_revision(self : BoardState) -> Unit {
  self.revision = self.revision + 1L
}
