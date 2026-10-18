///|
fn DynamicWorkflowController::new_proposal(
  self : DynamicWorkflowController,
  authorization_id : String,
  parent : String,
  deadline_ms : Int64,
) -> Result[(@expansion.ExpansionHost, Int64), DynamicWorkflowError] {
  match self.gate() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let expansion = match self.spec.expansion {
    Some(e) => e
    None => return Err(ExpansionDisabled)
  }
  if self.op is Some(_) || self.uncertain is Some(_) {
    return Err(ProposalActive)
  }
  if !valid_id(authorization_id) ||
    self.used_authorities.contains(authorization_id) {
    return Err(InvalidSpec)
  }
  if !self.runner.authorized_scope().contains(parent) {
    return Err(ParentOutOfScope)
  }
  if self.reservations.max(self.expansions_committed) >=
    expansion.max_expansions ||
    self.generated_tasks_committed >= expansion.max_generated_tasks {
    return Err(BudgetExceeded)
  }
  let remaining = self.runner.status().remaining_ms
  let deadline = deadline_ms.min((self.now_ms)() + remaining)
  if deadline <= (self.now_ms)() {
    return Err(BudgetExceeded)
  }
  self.used_authorities.add(authorization_id)
  self.reservations = self.reservations.max(self.expansions_committed) + 1
  self.expansions_attempted += 1
  let host = @expansion.ExpansionHost(
    backend=self.backend,
    policy=self.policy,
    now_ms=self.now_ms,
  )
  self.op = Some(host)
  Ok((host, deadline))
}

///|
fn DynamicWorkflowController::finish_proposal(
  self : DynamicWorkflowController,
  host : @expansion.ExpansionHost,
) -> Unit {
  self.last_expansion_phase = Some(host.phase())
  if host.phase() is Uncertain {
    self.uncertain = Some(host)
  }
  if self.op is Some(current) && physical_equal(current, host) {
    self.op = None
  }
  if !(host.phase() is Uncertain) {
    self.pending_id = None
  }
}

///|
/// Raw host-held content is still untrusted. This does not run an Agent. Parent
/// authority is derived from the controller's live scope, never supplied JSON.
pub async fn DynamicWorkflowController::prepare_proposal(
  self : DynamicWorkflowController,
  payload~ : String,
  authorization_id~ : String,
  workflow_parent~ : String,
  permitted_existing_dependencies~ : Array[String] = [],
  deadline_ms~ : Int64,
  max_tasks~ : Int32 = 20,
  max_edges~ : Int32 = 60,
) -> Result[Unit, DynamicWorkflowError] {
  let dependencies = permitted_existing_dependencies.copy()
  self.perform(() => {
    let (host, deadline) = match
      self.new_proposal(authorization_id, workflow_parent, deadline_ms) {
      Ok(value) => value
      Err(e) => return Err(e)
    }
    let mut validated = false
    defer (if !validated { self.finish_proposal(host) })
    let authorization = @expansion.ExpansionAuthorization(
      authorization_id~,
      workflow=self.spec.workflow_id,
      workflow_parent~,
      workflow_task_scope=[workflow_parent],
      permitted_existing_dependencies=dependencies,
      deadline_ms=deadline,
      max_tasks~,
      max_edges~,
    )
    match host.prepare(payload, authorization=Some(authorization)) {
      Err(e) => Err(ExpansionFailed(e))
      Ok(_) => {
        validated = true
        Ok(())
      }
    }
  })
}

///|
/// One explicitly requested planning run over the same S4A owner. The private
/// channel must be wired into that owner's planning adapter by the trusted host.
pub async fn DynamicWorkflowController::generate_plan(
  self : DynamicWorkflowController,
  request~ : @execution.BoardExecutionRequest,
  channel~ : @execution.BoardExecutionResultChannel,
  authorization_id~ : String,
  workflow_parent~ : String,
  permitted_existing_dependencies~ : Array[String] = [],
  deadline_ms~ : Int64,
  max_tasks~ : Int32 = 20,
  max_edges~ : Int32 = 60,
) -> Result[Unit, DynamicWorkflowError] {
  let dependencies = permitted_existing_dependencies.copy()
  self.perform(() => {
    match self.at_boundary() {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    if request.task_id != workflow_parent ||
      !valid_id(request.attempt_id) ||
      !valid_id(request.execution_id) ||
      !valid_id(request.session_id) ||
      self.owner
      .bindings()
      .any(b => {
        b.execution_id == request.execution_id ||
        b.attempt_id == request.attempt_id ||
        b.session_id == request.session_id
      }) {
      return Err(InvalidSpec)
    }
    let timeout = match request.timeout_ms {
      Some(ms) if ms > 0 && ms <= self.spec.execution_timeout_ms => ms
      _ => return Err(InvalidSpec)
    }
    let (host, deadline) = match
      self.new_proposal(authorization_id, workflow_parent, deadline_ms) {
      Ok(value) => value
      Err(e) => return Err(e)
    }
    let mut validated = false
    defer (if !validated { self.finish_proposal(host) })
    if timeout.to_int64() > deadline - (self.now_ms)() {
      return Err(BudgetExceeded)
    }
    match self.runner.begin_planning() {
      Err(e) => return Err(RunnerRejected(e))
      Ok(_) => ()
    }
    self.planning_active = true
    defer @async.protect_from_cancel(() => {
      self.planning_active = false
      let binding = find_first(self.owner.bindings(), b => {
        b.execution_id == request.execution_id &&
        b.task_id == request.task_id &&
        b.attempt_id == request.attempt_id &&
        b.session_id == request.session_id
      })
      match self.runner.end_planning(binding~) {
        Ok(_) => ()
        Err(_) => self.unresolved = true
      }
    })
    let context : @expansion.DynamicPlanContext = {
      workflow_parent,
      workflow: Some(self.spec.workflow_id),
      authorization_id,
      permitted_existing_dependencies: dependencies.copy(),
      max_new_tasks: max_tasks.min(self.policy.max_tasks()),
      max_new_edges: max_edges.min(self.policy.max_edges()),
      max_payload_bytes: self.policy.max_payload_bytes(),
      deadline_ms: deadline,
    }
    let source = @agent.OwnedAgentPlanSource(
      owner=self.owner,
      channel~,
      request~,
      context~,
      now_ms=self.now_ms,
      authorize=ctx => {
        !self.closed &&
        !self.cancel_requested &&
        !self.host_paused &&
        self.planning_active &&
        self.runner.planning_gate() &&
        ctx == context
      },
    )
    let authorization = @expansion.ExpansionAuthorization(
      authorization_id~,
      workflow=self.spec.workflow_id,
      workflow_parent~,
      workflow_task_scope=[workflow_parent],
      permitted_existing_dependencies=dependencies,
      deadline_ms=deadline,
      max_tasks~,
      max_edges~,
    )
    match host.generate(source, authorization=Some(authorization)) {
      Err(e) => Err(ExpansionFailed(e))
      Ok(_) => {
        validated = true
        Ok(())
      }
    }
  })
}
