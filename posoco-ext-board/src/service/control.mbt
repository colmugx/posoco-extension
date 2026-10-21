///|
/// A trusted, revocable in-process lease over already authorized work. This
/// carries no graph/scope authority and never replenishes the runner's budget.
pub struct BoardWorkflowControl {
  priv workflows : BoardWorkflows
  priv workflow_id : String
  priv scope : Array[String]
  priv original_scope : Array[String]
  priv deadline_ms : Int64
  priv max_runs : Int32
  priv authorize : () -> Bool
  priv mut runs : Int32
  priv mut revoked : Bool
  priv mut running : Bool
  priv prepared : Map[String, String]
  priv versions : Map[String, @domain.BoardTask]
  priv settled : Map[String, @execution.BoardExecutionBinding]
  priv consumed : Set[String]
  priv attempted : Set[String]
}

///|
/// Issued only after a trusted host's separate execution-session approval.
/// The live guard must keep that approval, permission and configuration valid.
pub async fn BoardWorkflows::authorize_control(
  self : BoardWorkflows,
  workflow_id~ : String,
  task_ids~ : Array[String],
  expected_revision~ : Int64,
  max_runs~ : Int32,
  deadline_ms~ : Int64,
  authorize~ : () -> Bool = () => false,
  capture_after_successful_tools~ : Bool = false,
) -> Result[BoardWorkflowControl, BoardWorkflowError] {
  self.perform(() => {
    let controller = self.running()
    let status = controller.status()
    if self.control_issued { raise WorkflowFault(Busy) }
    let snapshot = self.snapshot()
    if snapshot.revision != expected_revision { raise WorkflowFault(RevisionConflict) }
    if workflow_id != self.workflow.val || task_ids.is_empty() ||
      task_ids.length() > 200 || max_runs < 1 ||
      max_runs > status.runner.remaining_executions ||
      status.pending_proposal_id is Some(_) || !(authorize)() {
      raise WorkflowFault(OperationRejected)
    }
    let scope = task_ids.copy()
    let seen : Set[String] = Set([])
    for id in scope {
      if seen.contains(id) || !status.scope.contains(id) ||
        !snapshot.expansions.any(e => e.workflow_id == workflow_id &&
          status.scope.contains(e.parent_task_id.value) &&
          e.mapping.any(m => m.task_id.value == id)) {
        raise WorkflowFault(OperationRejected)
      }
      seen.add(id)
    }
    let owner = self.owner.unwrap()
    if status.phase != @workflow.Paused || status.operation_active ||
      !owner.status().active_bindings.is_empty() || owner.status().admission_busy {
      raise WorkflowFault(NotQuiescent)
    }
    let deadline = self.deadline.unwrap_or(0L).min(deadline_ms)
    if deadline <= (self.clock)() { raise WorkflowFault(BudgetExceeded) }
    self.discard_settled_results()
    for channel in self.channels {
      if !channel.set_strategy(if capture_after_successful_tools {
          @execution.FinalAfterSuccessfulTools
        } else { @execution.ToolFreeFinal }) {
        raise WorkflowFault(NotQuiescent)
      }
    }
    self.control_issued = true
    {
      workflows: self, workflow_id, scope,
      original_scope: status.scope.copy(), deadline_ms: deadline, max_runs,
      authorize, runs: 0, revoked: false, running: false,
      prepared: Map([]), versions: Map([]), settled: Map([]),
      consumed: Set([]), attempted: Set([]),
    }
  })
}

///|
fn BoardWorkflowControl::active(self : BoardWorkflowControl) -> Bool {
  let w = self.workflows
  let allowed = (w.authorize)() && (self.authorize)()
  !self.revoked && !w.closed && !w.stopped && !w.paused && !w.uncertain &&
  !w.unresolved && w.live.val && allowed &&
  w.workflow.val == self.workflow_id && (w.clock)() < self.deadline_ms &&
  w.controller.map(c => c.status().scope == self.original_scope).unwrap_or(false)
}

///|
fn BoardWorkflowControl::check(self : BoardWorkflowControl) -> Unit raise WorkflowFault {
  if !self.active() { raise WorkflowFault(Closed) }
}

///|
/// Board mints all execution identities. Preparation is three independently
/// durable commands; a partial/uncertain result is not permission to retry.
pub async fn BoardWorkflowControl::prepare(
  self : BoardWorkflowControl,
  task_id~ : String,
  input~ : String,
  expected_revision~ : Int64,
) -> Result[String, BoardWorkflowError] {
  let w = self.workflows
  w.perform(() => {
    self.check()
    if !self.scope.contains(task_id) || self.prepared.contains(task_id) ||
      self.running || input.trim().is_empty() || input.length() > 32768 {
      raise WorkflowFault(OperationRejected)
    }
    if self.runs >= self.max_runs { raise WorkflowFault(BudgetExceeded) }
    let snapshot = w.snapshot()
    if snapshot.revision != expected_revision { raise WorkflowFault(RevisionConflict) }
    let attempt_id = w.mint("attempt")
    // Keep the identity even when preparation fails. Never remint/replay it.
    self.prepared[task_id] = attempt_id
    w.inputs.values[attempt_id] = (task_id, {
      execution_id: w.mint("execution"), session_id: w.mint("session"),
      input, timeout_ms: Some(w.policy.execution_timeout_ms),
    })
    ignore(controller_result(w.running().prepare_task(task_id~, attempt_id~, expected_revision~)))
    let after = w.snapshot()
    guard after.tasks.iter().find_first(t => t.id.value == task_id) is Some(task) else {
      raise WorkflowFault(OperationRejected)
    }
    self.versions[task_id] = task.copy_detached()
    attempt_id
  })
}

///|
/// Read the existing S4B planner; no alternate DAG scheduler is involved.
pub async fn BoardWorkflowControl::plan(
  self : BoardWorkflowControl,
) -> Result[@orchestration.ExecutionPlan, BoardWorkflowError] {
  let w = self.workflows
  w.perform(() => {
    self.check()
    let plan = controller_result(w.running().execution_plan(self.scope))
    { ..plan, eligible: plan.eligible.filter(c =>
      self.prepared.get(c.task_id) == Some(c.attempt_id) &&
      !self.attempted.contains(c.attempt_id)) }
  })
}

///|
/// Dispatch and join one bounded S4D wave. The initial planner chooses the
/// exact candidates; every model gate rechecks their live grant and eligibility.
pub async fn BoardWorkflowControl::run_wave(
  self : BoardWorkflowControl,
) -> Result[Unit, BoardWorkflowError] {
  let w = self.workflows
  w.perform(() => {
    self.check()
    if self.running { raise WorkflowFault(Busy) }
    if self.runs >= self.max_runs { raise WorkflowFault(BudgetExceeded) }
    if self.settled.keys().any(id => !self.consumed.contains(id)) {
      raise WorkflowFault(OperationRejected)
    }
    let controller = w.running()
    let plan = controller_result(controller.execution_plan(self.scope))
    let candidates = plan.eligible.filter(c =>
      self.prepared.get(c.task_id) == Some(c.attempt_id) &&
      !self.attempted.contains(c.attempt_id))
      .iter().take((self.max_runs - self.runs).min(w.policy.max_concurrency)).to_array()
    if candidates.is_empty() { raise WorkflowFault(OperationRejected) }
    let before = w.snapshot()
    for candidate in candidates {
      if before.tasks.iter().find_first(t => t.id.value == candidate.task_id) !=
        self.versions.get(candidate.task_id) {
        raise WorkflowFault(RevisionConflict)
      }
      // Conservatively burn candidates even when admission becomes ambiguous.
      self.attempted.add(candidate.attempt_id)
    }
    self.running = true
    defer {
      controller.clear_control_scope()
      self.running = false
      if self.revoked { self.release_if_quiescent() }
    }
    self.runs += candidates.length()
    ignore(controller_result(controller.run_wave_scoped(candidates,
      authorize=() => self.active())))
    ignore(controller_result(controller.wait_boundary()))
    let bindings = w.owner.unwrap().bindings()
    for candidate in candidates {
      match bindings.iter().find_first(b => b.attempt_id == candidate.attempt_id) {
        Some(binding) if binding.phase is @execution.Settled =>
          self.settled[candidate.task_id] = binding
        _ => raise WorkflowFault(UnresolvedExecution)
      }
    }
  })
}

///|
/// Only exact identity metadata is durable. Text is bounded ephemeral output,
/// never proof, and absent text never changes an execution's settled outcome.
pub(all) struct BoardWorkflowControlResult {
  binding : @execution.BoardExecutionBinding
  assistant_text : String?
}

///|
pub async fn BoardWorkflowControl::take_results(
  self : BoardWorkflowControl,
) -> Result[Array[BoardWorkflowControlResult], BoardWorkflowError] {
  self.workflows.perform(recovery=true, () => {
    if self.running { raise WorkflowFault(NotQuiescent) }
    let results : Array[BoardWorkflowControlResult] = []
    for id, binding in self.settled {
      if self.consumed.contains(id) { continue }
      self.consumed.add(id)
      let mut assistant_text : String? = None
      for channel in self.workflows.channels {
        if channel.take(binding) is Some(text) { assistant_text = Some(text) }
      }
      results.push({ binding, assistant_text })
    }
    results
  })
}

///|
/// The trusted host supplies a fresh verification baseline for ONE legal
/// transition. No review decision is recorded. Multi-stage completion is not
/// atomic and every stage must use its newly confirmed revision.
pub async fn BoardWorkflowControl::transition(
  self : BoardWorkflowControl,
  task_id~ : String,
  to~ : @domain.BoardStage,
  expected_revision~ : Int64,
) -> Result[Int64, BoardWorkflowError] {
  let w = self.workflows
  w.perform(() => {
    self.check()
    if !(to is (@domain.Running | @domain.Review | @domain.Done)) ||
      !self.consumed.contains(task_id) {
      raise WorkflowFault(OperationRejected)
    }
    guard self.settled.get(task_id) is Some(binding) &&
      binding.phase is @execution.Settled && binding.outcome == Some(@execution.Completed) else {
      raise WorkflowFault(OperationRejected)
    }
    let status = w.running().status()
    if self.running || status.phase != @workflow.Paused || status.operation_active ||
      !w.owner.unwrap().status().active_bindings.is_empty() {
      raise WorkflowFault(NotQuiescent)
    }
    let snapshot = w.snapshot()
    if snapshot.revision != expected_revision { raise WorkflowFault(RevisionConflict) }
    guard snapshot.tasks.iter().find_first(t => t.id.value == task_id) is Some(task) &&
      self.versions.get(task_id) == Some(task) else { raise WorkflowFault(RevisionConflict) }
    if !snapshot.attempts.any(a => a.task_id.value == task_id &&
        a.id.value == binding.attempt_id && a.kind is @domain.Execute && a.status is @domain.Succeeded) ||
      snapshot.attempts.any(a => a.task_id.value == task_id &&
        (a.kind is @domain.Review || (a.id.value != binding.attempt_id && a.kind is @domain.Execute))) ||
      task.dependencies.any(id => !snapshot.tasks.any(d => d.id == id && d.stage is @domain.Done)) {
      raise WorkflowFault(OperationRejected)
    }
    w.submit(@domain.MoveTask(id=task.id, to~, at_ms=(w.clock)(), expected_revision~))
    let after = w.snapshot()
    guard after.tasks.iter().find_first(t => t.id.value == task_id) is Some(updated) else {
      raise WorkflowFault(OperationRejected)
    }
    self.versions[task_id] = updated.copy_detached()
    after.revision
  })
}

///|
fn BoardWorkflowControl::release_if_quiescent(self : BoardWorkflowControl) -> Unit {
  let w = self.workflows
  if !self.running && w.owner is Some(owner) &&
    owner.status().active_bindings.is_empty() && !owner.status().admission_busy &&
    !owner.status().unresolved {
    w.discard_settled_results()
    for channel in w.channels { ignore(channel.set_strategy(@execution.ToolFreeFinal)) }
    w.control_issued = false
  }
}

///|
/// Revocation stops NEW admission/mutations. Actual active Agents retain their
/// identities; hosts use Board's existing pause/stop/cancel semantics to settle.
pub fn BoardWorkflowControl::revoke(self : BoardWorkflowControl) -> Unit {
  if self.revoked { return }
  self.revoked = true
  self.release_if_quiescent()
}
