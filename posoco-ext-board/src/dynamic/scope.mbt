///|
/// Separate trusted-host execution authorization for exactly the complete
/// canonical mapping of one durable expansion. No budgets are added or reset.
pub async fn DynamicWorkflowController::authorize_scope_extension(
  self : DynamicWorkflowController,
  workflow_id~ : String,
  expansion_id~ : String,
  approved_task_ids~ : Array[String],
  expected_revision~ : Int64,
  approver~ : &ScopeExtensionApprover,
) -> Result[Unit, DynamicWorkflowError] {
  let requested = approved_task_ids.copy()
  self.perform(() => {
    match self.at_boundary() {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    if self.op is Some(_) || self.uncertain is Some(_) {
      return Err(ProposalActive)
    }
    if workflow_id != self.spec.workflow_id {
      return Err(WorkflowMismatch)
    }
    let bounds = match self.spec.expansion {
      Some(e) if e.scope_approval is HostApprover => e
      _ => return Err(ScopeApprovalDenied)
    }
    let seen : Set[String] = Set([])
    for id in requested {
      if !valid_id(id) || seen.contains(id) {
        return Err(InvalidScope)
      }
      seen.add(id)
    }
    if requested.is_empty() {
      return Err(InvalidScope)
    }
    if self.authorized.get(expansion_id) is Some(previous) {
      if previous.length() == requested.length() &&
        previous.all(id => seen.contains(id)) {
        return Ok(())
      }
      return Err(DuplicateAuthorization)
    }
    let snapshot = match self.backend.state() {
      Ok(s) => s
      Err(_) => return Err(BoardUnavailable)
    }
    self.observe(snapshot)
    if snapshot.revision != expected_revision {
      return Err(StaleRevision)
    }
    let record = match
      find_first(snapshot.expansions, r => r.expansion_id.value == expansion_id) {
      Some(r) => r
      None => return Err(UnknownExpansion)
    }
    if record.workflow_id != workflow_id {
      return Err(WorkflowMismatch)
    }
    let prior = self.runner.authorized_scope()
    if !prior.contains(record.parent_task_id.value) {
      return Err(ParentOutOfScope)
    }
    let ids = record.mapping.map(p => p.task_id.value)
    if ids.length() != requested.length() ||
      !ids.all(id => seen.contains(id)) ||
      ids.any(id => {
        prior.contains(id) || !snapshot.tasks.any(t => t.id.value == id)
      }) {
      return Err(InvalidScope)
    }
    if self.expansions_committed > bounds.max_expansions ||
      self.generated_tasks_committed > bounds.max_generated_tasks ||
      self.runner.status().remaining_executions <= 0 {
      return Err(BudgetExceeded)
    }
    let preview : ScopeExtensionPreview = {
      workflow_id,
      expansion_id,
      parent_task_id: record.parent_task_id.value,
      mapping: record.mapping.map(p => {
        key: p.local_ref,
        task_id: p.task_id.value,
      }),
      approved_task_ids: requested.copy(),
      revision: expected_revision,
      scope_before: prior,
      expansions_committed: self.expansions_committed,
      scope_authorizations: self.scope_authorizations,
    }
    if approver.approve(preview) != @expansion.Grant {
      return Err(ApprovalDenied)
    }
    match self.at_boundary() {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    match self.runner.extend_scope(ids=requested, expected_revision~) {
      Err(e) => Err(RunnerRejected(e))
      Ok(_) => {
        self.authorized[expansion_id] = requested.copy()
        self.scope_authorizations += 1
        self.refresh_status().map(_ => ())
      }
    }
  })
}
