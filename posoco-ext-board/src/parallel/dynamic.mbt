///|
pub async fn ParallelWorkflowRunner::start(
  self : ParallelWorkflowRunner,
  spec : ParallelWorkflowSpec,
) -> Result[Unit, @workflow.WorkflowError] {
  self.start_inner(spec, controlled=false)
}

///|
/// Opt-in host-controlled waves. Starts paused and returns to the admission
/// boundary after a fully settled wave, including an empty plan. Budgets and
/// the original deadline never change when scope is extended.
pub async fn ParallelWorkflowRunner::start_controlled(
  self : ParallelWorkflowRunner,
  spec : ParallelWorkflowSpec,
) -> Result[Unit, @workflow.WorkflowError] {
  self.start_inner(spec, controlled=true)
}

///|
pub fn ParallelWorkflowRunner::authorized_scope(
  self : ParallelWorkflowRunner,
) -> Array[String] {
  self.scope.copy()
}

///|
fn ParallelWorkflowRunner::boundary_idle(self : ParallelWorkflowRunner) -> Bool {
  let owner = self.orchestrator.owner_status()
  self.controlled &&
  self.phase is Paused &&
  !self.starting &&
  !self.closed &&
  !self.cancel_requested &&
  !self.stop_requested &&
  !self.deadline_expired &&
  !self.planning &&
  self.handles.is_empty() &&
  owner.active_bindings.is_empty() &&
  !owner.admission_busy &&
  !owner.unresolved &&
  self.spec.map(spec => self.has_time(spec)).unwrap_or(false)
}

///|
/// A read-only admission boundary, not authorization to mutate a graph.
pub fn ParallelWorkflowRunner::quiescent(self : ParallelWorkflowRunner) -> Bool {
  !self.scope_busy && self.boundary_idle()
}

///|
/// Trusted caller must first validate durable lineage and obtain scope approval.
/// Input is detached before the Board read; pause/resume cannot race this
/// boundary, and cancellation is rechecked after the read. Only a union is made.
pub async fn ParallelWorkflowRunner::extend_scope(
  self : ParallelWorkflowRunner,
  ids~ : Array[String],
  expected_revision~ : Int64,
) -> Result[Unit, @workflow.WorkflowError] {
  if !self.quiescent() {
    return Err(@workflow.AlreadyRunning)
  }
  let detached = ids.copy()
  let seen : Set[String] = Set([])
  if detached.is_empty() || detached.length() + self.scope.length() > 10000 {
    return Err(@workflow.InvalidScope)
  }
  for id in detached {
    if id.is_empty() ||
      id.length() > 128 ||
      id.iter().any(ch => ch.is_whitespace() || ch.is_control()) ||
      seen.contains(id) {
      return Err(@workflow.InvalidScope)
    }
    seen.add(id)
  }
  self.scope_busy = true
  defer {
    self.scope_busy = false
  }
  let state = match self.orchestrator.board_state() {
    Ok(state) => state
    Err(_) => return Err(@workflow.BoardUnavailable)
  }
  if !self.boundary_idle() {
    return Err(@workflow.AlreadyRunning)
  }
  if state.revision != expected_revision ||
    detached.any(id => !state.tasks.any(task => task.id.value == id)) {
    return Err(@workflow.InvalidScope)
  }
  for id in detached {
    if !self.scope.contains(id) {
      self.scope.push(id)
    }
  }
  self.revision = Some(state.revision)
  Ok(())
}

///|
/// Reserves one shared execution-budget unit conservatively before an S4A
/// planning admission. Even a pre-admission rejection does not replenish it.
/// The exclusive controller must end the reservation after the source joins.
pub fn ParallelWorkflowRunner::begin_planning(
  self : ParallelWorkflowRunner,
) -> Result[Unit, @workflow.WorkflowError] {
  if !self.quiescent() {
    return Err(@workflow.AlreadyRunning)
  }
  let spec = self.spec.unwrap()
  if self.admitted >= spec.max_executions {
    return Err(@workflow.InvalidSpec)
  }
  self.planning = true
  self.admitted += 1
  Ok(())
}

///|
pub fn ParallelWorkflowRunner::planning_gate(
  self : ParallelWorkflowRunner,
) -> Bool {
  self.planning &&
  self.phase is Paused &&
  !self.closed &&
  !self.cancel_requested &&
  !self.stop_requested &&
  !self.deadline_expired &&
  self.status().remaining_ms > 0L &&
  !self.orchestrator.owner_status().unresolved
}

///|
/// The supplied binding is the exact result of the reserved S4A planning run,
/// not an Observer-derived result. Unconfirmed owner quiescence fails closed.
pub fn ParallelWorkflowRunner::end_planning(
  self : ParallelWorkflowRunner,
  binding~ : @execution.BoardExecutionBinding?,
) -> Result[Unit, @workflow.WorkflowError] {
  if !self.planning {
    return Err(@workflow.InvalidSpec)
  }
  self.planning = false
  let owner = self.orchestrator.owner_status()
  if owner.unresolved ||
    owner.admission_busy ||
    !owner.active_bindings.is_empty() {
    self.finish(@workflow.Unresolved, @workflow.UnconfirmedSettlement)
    return Err(@workflow.UnresolvedOwner)
  }
  if binding is Some(binding) {
    if self.accounted.contains(binding.execution_id) ||
      !self.account({
        execution_id: binding.execution_id,
        binding: Some(binding),
      }) {
      self.finish(@workflow.Unresolved, @workflow.UnconfirmedSettlement)
      return Err(@workflow.UnresolvedOwner)
    }
    if self.phase is Paused &&
      !self.cancel_requested &&
      !self.closed &&
      binding.outcome is Some(outcome) &&
      outcome != @execution.Completed &&
      self.spec.unwrap().failure_policy != ContinueOnConfirmedFailure {
      self.finish(@workflow.Failed, @workflow.ExecutionFailed(outcome))
    }
  }
  Ok(())
}
