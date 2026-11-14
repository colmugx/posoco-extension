///|
/// Explicit initial preparation of a generated, separately scope-authorized
/// task. Three independent durable commands, not a graph transaction. No retry
/// path exists for a task whose preparation has already been attempted.
pub async fn DynamicWorkflowController::prepare_task(
  self : DynamicWorkflowController,
  task_id~ : String,
  attempt_id~ : String,
  expected_revision~ : Int64,
) -> Result[Unit, DynamicWorkflowError] {
  self.perform(() => {
    match self.at_boundary() {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    if self.op is Some(_) || self.uncertain is Some(_) {
      return Err(ProposalActive)
    }
    if !valid_id(task_id) || !valid_id(attempt_id) {
      return Err(InvalidPreparation)
    }
    if !self.authorized.values().any(ids => ids.contains(task_id)) {
      return Err(TaskOutOfScope)
    }
    if self.partials.any(r => r.task_id == task_id || r.attempt_id == attempt_id) {
      return Err(PreparationBlocked)
    }
    if self.runner.status().remaining_executions <= 0 {
      return Err(BudgetExceeded)
    }
    let snapshot = match self.backend.state() {
      Ok(s) => s
      Err(_) => return Err(BoardUnavailable)
    }
    if snapshot.revision != expected_revision {
      return Err(StaleRevision)
    }
    let task = match find_first(snapshot.tasks, t => t.id.value == task_id) {
      Some(t) => t
      None => return Err(TaskOutOfScope)
    }
    if !(task.stage is @domain.Created) ||
      snapshot.attempts.any(a => {
        a.id.value == attempt_id ||
        (a.task_id.value == task_id && a.kind is @domain.Execute)
      }) {
      return Err(InvalidPreparation)
    }
    let index = self.partials.length()
    self.partials.push({
      task_id,
      attempt_id,
      step: MoveRefining,
      uncertain: false,
      base_revision: expected_revision,
      completed_steps: 0,
    })
    let tid = @domain.BoardTaskId(task_id)
    let aid = @domain.AttemptId(attempt_id)
    let commands = [
      (
        MoveRefining,
        @domain.MoveTask(
          id=tid,
          to=@domain.Refining,
          at_ms=(self.now_ms)(),
          expected_revision~,
        ),
      ),
      (
        MoveReady,
        @domain.MoveTask(
          id=tid,
          to=@domain.Ready,
          at_ms=(self.now_ms)(),
          expected_revision=expected_revision + 1L,
        ),
      ),
      (
        QueueExecute,
        @domain.QueueAttempt(
          id=aid,
          task=tid,
          kind=@domain.Execute,
          at_ms=(self.now_ms)(),
          expected_revision=expected_revision + 2L,
        ),
      ),
    ]
    for step_index, pair in commands {
      match self.at_boundary() {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      let (step, command) = pair
      let result = @async.protect_from_cancel(() => {
        self.partials[index] = {
          ..self.partials[index],
          step,
          uncertain: true,
        }
        let submitted = self.backend.submit(command)
        match submitted {
          Ok(_) =>
            self.partials[index] = {
              ..self.partials[index],
              uncertain: false,
              completed_steps: step_index + 1,
            }
          Err(@coordinator.Rejected(_) | @coordinator.PersistFailed(_)) =>
            self.partials[index] = { ..self.partials[index], uncertain: false, }
          Err(_) => ()
        }
        submitted
      })
      match result {
        Ok(_) => ()
        Err(e) => {
          if self.partials[index].uncertain {
            return Err(PreparationUncertain(self.partials[index]))
          }
          return Err(PreparationFailed(e))
        }
      }
    }
    self.refresh_status().map(_ => ())
  })
}

///|
/// Inspection only. An exact unique Attempt proves the final queue step landed;
/// absence or a partial stage leaves the operation frozen. Never resubmits any
/// command. A host may separately repair partial preparation using domain APIs.
pub async fn DynamicWorkflowController::reconcile_preparation(
  self : DynamicWorkflowController,
  task_id~ : String,
) -> Result[PreparationRecord, DynamicWorkflowError] {
  self.perform(recovery=true, () => {
    let mut index = -1
    for i, record in self.partials {
      if record.task_id == task_id {
        index = i
        break
      }
    }
    if index < 0 {
      return Err(InvalidPreparation)
    }
    let record = self.partials[index]
    let snapshot = match self.backend.state() {
      Ok(s) => s
      Err(_) => return Err(BoardUnavailable)
    }
    self.observe(snapshot)
    if snapshot.attempts.any(a => {
        a.id.value == record.attempt_id &&
        a.task_id.value == task_id &&
        a.kind is @domain.Execute
      }) {
      self.partials[index] = {
        ..record,
        completed_steps: 3,
        uncertain: false,
        step: QueueExecute,
      }
    }
    Ok(self.partials[index])
  })
}
