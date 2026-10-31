///|
/// Compare timestamps without subtraction, preserving ordering at Int64 bounds.
fn compare_creation_times(left : Int64, right : Int64) -> Int32 {
  if left < right {
    -1
  } else if left > right {
    1
  } else {
    0
  }
}

///|
/// Deterministic listing order; ids make the order total.
fn compare_task_order(a : BoardTask, b : BoardTask) -> Int32 {
  let rank = b.priority.rank() - a.priority.rank()
  if rank != 0 {
    return rank
  }
  let created_order = compare_creation_times(a.created_at_ms, b.created_at_ms)
  if created_order != 0 {
    return created_order
  }
  a.id.value.compare(b.id.value)
}

///|
fn compare_attempt_order(a : Attempt, b : Attempt) -> Int32 {
  let created_order = compare_creation_times(a.created_at_ms, b.created_at_ms)
  if created_order != 0 {
    return created_order
  }
  a.id.value.compare(b.id.value)
}

///|
fn compare_expansion_order(a : ExpansionRecord, b : ExpansionRecord) -> Int32 {
  let created_order = compare_creation_times(a.created_at_ms, b.created_at_ms)
  if created_order != 0 {
    return created_order
  }
  a.expansion_id.value.compare(b.expansion_id.value)
}

///|
/// Array-bearing records are always copied, never shared across state
/// boundaries.
pub fn BoardTask::copy_detached(self : BoardTask) -> BoardTask {
  {
    ..self,
    definition_of_done: self.definition_of_done.copy(),
    dependencies: self.dependencies.copy(),
    assignments: self.assignments.copy(),
    required_roles: self.required_roles.copy(),
    review: match self.review {
      Some(report) => Some(report.copy_detached())
      None => None
    },
  }
}

///|
pub fn ReviewReport::copy_detached(self : ReviewReport) -> ReviewReport {
  {
    outcome: self.outcome,
    summary: self.summary,
    changes: self.changes.copy(),
    verification: self.verification.copy(),
    risks: self.risks.copy(),
    notes: self.notes.copy(),
    open_questions: self.open_questions.copy(),
    artifacts: self.artifacts.copy(),
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
  let expansions : Map[ExpansionId, ExpansionRecord] = Map::from_array([])
  for id, record in self.expansions {
    expansions[id] = record.copy_detached()
  }
  { revision: self.revision, tasks, attempts, expansions, }
}
