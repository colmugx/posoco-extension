///|
pub async fn DynamicWorkflowController::preview(
  self : DynamicWorkflowController,
) -> Result[@expansion.ExpansionApprovalPreview, DynamicWorkflowError] {
  self.perform(() => {
    let host = match self.op {
      Some(h) => h
      None => return Err(NoActiveProposal)
    }
    match host.preview() {
      Ok(preview) => {
        self.pending_id = Some(preview.proposal_id)
        Ok(preview)
      }
      Err(e) => {
        self.finish_proposal(host)
        Err(ExpansionFailed(e))
      }
    }
  })
}

///|
/// Graph approval is not execution-scope approval. Reentrant host callbacks
/// cannot cancel/pause and still leave a usable approval behind.
pub fn DynamicWorkflowController::approve(
  self : DynamicWorkflowController,
  preview~ : @expansion.ExpansionApprovalPreview,
  approver~ : &@expansion.ExpansionApprover,
) -> Result[@expansion.ExpansionApproval, DynamicWorkflowError] {
  if self.busy {
    return Err(Busy)
  }
  match self.gate() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let host = match self.op {
    Some(h) => h
    None => return Err(NoActiveProposal)
  }
  self.busy = true
  defer {
    self.busy = false
  }
  let result = host.approve(preview, approver)
  match self.gate() {
    Err(e) => {
      self.finish_proposal(host)
      return Err(e)
    }
    Ok(_) => ()
  }
  match result {
    Ok(approval) => Ok(approval)
    Err(e) => {
      self.finish_proposal(host)
      Err(ExpansionFailed(e))
    }
  }
}

///|
/// Atomic S4E1 commit at the quiescent boundary. On cancellation the host's
/// Uncertain identity/mapping remains retained; no resubmission path exists.
pub async fn DynamicWorkflowController::commit(
  self : DynamicWorkflowController,
  approval~ : @expansion.ExpansionApproval,
) -> Result[Unit, DynamicWorkflowError] {
  self.perform(() => {
    match self.at_boundary() {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    let host = match self.op {
      Some(h) => h
      None => return Err(NoActiveProposal)
    }
    defer self.finish_proposal(host)
    match host.commit(approval) {
      Err(e) => Err(ExpansionFailed(e))
      Ok(_) => {
        self.last_id = self.pending_id
        self.refresh_status().map(_ => ())
      }
    }
  })
}

///|
/// Read-only, including after pause/cancel. Missing evidence retains the
/// frozen identity and blocks another proposal; it never permits replay.
pub async fn DynamicWorkflowController::reconcile(
  self : DynamicWorkflowController,
) -> Result[Bool, DynamicWorkflowError] {
  self.perform(recovery=true, () => {
    let host = match self.uncertain {
      Some(h) => h
      None => return Err(NoUncertainProposal)
    }
    match host.reconcile() {
      Ok(true) => {
        self.last_expansion_phase = Some(@expansion.Committed)
        self.last_id = self.pending_id
        self.pending_id = None
        self.uncertain = None
        self.refresh_status().map(_ => true)
      }
      Ok(false) => Ok(false)
      Err(e) => {
        if host.phase() is Conflict {
          self.last_expansion_phase = Some(@expansion.Conflict)
          self.pending_id = None
          self.uncertain = None
        }
        Err(ExpansionFailed(e))
      }
    }
  })
}

///|
pub async fn DynamicWorkflowController::outlook(
  self : DynamicWorkflowController,
  expansion_id~ : String,
) -> Result[Array[@expansion.GeneratedTaskOutlook], DynamicWorkflowError] {
  let snapshot = match self.backend.state() {
    Ok(s) => s
    Err(_) => return Err(BoardUnavailable)
  }
  let record = match
    find_first(snapshot.expansions, r => r.expansion_id.value == expansion_id) {
    Some(r) => r
    None => return Err(UnknownExpansion)
  }
  if record.workflow_id != self.spec.workflow_id {
    return Err(WorkflowMismatch)
  }
  Ok(
    @expansion.expansion_execution_outlook(
      keys=record.mapping.map(p => p.local_ref),
      task_ids=record.mapping.map(p => p.task_id.value),
      snapshot~,
      workflow_task_scope=self.runner.authorized_scope(),
    ),
  )
}
