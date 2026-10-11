///|
/// Explicit dispatcher, not a background loop. All external effects and identity
/// persistence remain owned by the supplied single S4A owner.
pub struct BoardOrchestrator {
  priv owner : @execution.BoardExecutionOwner
  priv policy : ExecutionPolicy
  priv resolver : &BoardExecutionInputResolver
  priv mut busy : Bool
  priv mut closed : Bool
}

///|
/// The owner supplies both authoritative Board access and execution ownership.
/// Do not create multiple owners for one namespace or release its journal until
/// shutdown confirms join. Constructing this facade launches no tasks.
pub fn BoardOrchestrator::BoardOrchestrator(
  owner~ : @execution.BoardExecutionOwner,
  resolver~ : &BoardExecutionInputResolver,
  policy? : ExecutionPolicy = ExecutionPolicy(),
) -> BoardOrchestrator {
  { owner, policy, resolver, busy: false, closed: false, }
}

///|
fn BoardOrchestrator::plan_state(
  self : BoardOrchestrator,
  state : @domain.BoardStateSnapshot,
  include_dispatch_busy : Bool,
  status : @execution.BoardExecutionOwnerStatus,
) -> ExecutionPlan {
  let inputs = state.attempts
    .filter(attempt => {
      attempt.kind is @domain.Execute && attempt.status is @domain.Queued
    })
    .map(attempt => {
      let candidate : ExecutionCandidate = {
        task_id: attempt.task_id.value,
        attempt_id: attempt.id.value,
      }
      {
        task_id: candidate.task_id,
        attempt_id: candidate.attempt_id,
        status: self.resolver.availability(candidate),
      }
    })
  let plan = plan_execution(state, self.policy, inputs)
  let global : Array[ExecutionBlockReason] = []
  if self.closed || status.closed {
    global.push(OwnerClosed)
  }
  if !status.attached {
    global.push(OwnerNotAttached)
  }
  if status.unresolved {
    global.push(UnresolvedExecution)
  }
  if !status.host_available {
    global.push(HostUnavailable)
  }
  if status.active is Some(_) {
    global.push(ExecutionActive)
  }
  if status.admission_busy || (include_dispatch_busy && self.busy) {
    global.push(AdmissionInProgress)
  }
  let history = self.owner.bindings()
  let eligible : Array[ExecutionCandidate] = []
  let blocked = plan.blocked.map(row => {
    let reasons = row.reasons.copy()
    reasons.append(global)
    { ..row, reasons, }
  })
  for candidate in plan.eligible {
    let reasons = global.copy()
    if history.any(binding => binding.attempt_id == candidate.attempt_id) {
      reasons.push(IdentityAlreadyUsed)
    }
    if reasons.is_empty() {
      eligible.push(candidate)
    } else {
      blocked.push({
        task_id: candidate.task_id,
        attempt_id: Some(candidate.attempt_id),
        reasons,
      })
    }
  }
  { ..plan, eligible, blocked, }
}

///|
/// Pure planning plus live owner/input metadata inspection. No IDs reserved,
/// no input retained, no execution started. The result can become stale at once.
pub async fn BoardOrchestrator::plan(
  self : BoardOrchestrator,
) -> Result[ExecutionPlan, OrchestrationError] {
  match self.owner.board_state() {
    Ok(state) => Ok(self.plan_state(state, true, self.owner.status()))
    Err(_) => Err(BoardUnavailable)
  }
}

///|
/// Read-only operational status; active is actual owner metadata, never inferred
/// from a Task stage. Prompts and provider output are absent.
pub async fn BoardOrchestrator::status(
  self : BoardOrchestrator,
) -> Result[OrchestrationStatus, OrchestrationError] {
  match self.owner.board_state() {
    Ok(state) => {
      let owner = self.owner.status()
      Ok({
        policy_enabled: self.policy.enabled,
        admission_enabled: self.policy.enabled &&
        !self.closed &&
        !self.busy &&
        owner.attached &&
        !owner.closed &&
        !owner.admission_busy &&
        owner.host_available &&
        !owner.unresolved &&
        owner.active is None,
        dispatch_busy: self.busy,
        owner,
        plan: self.plan_state(state, true, owner),
      })
    }
    Err(_) => Err(BoardUnavailable)
  }
}

///|
/// One explicit call admits at most one run. Resolve is cancellable and must not
/// execute work. Revision changes during resolution return a fresh StalePlan,
/// requiring new host intent. No automatic selection fallback, replay or retry.
/// Cancellation after journal reservation requests exact-run cancellation and
/// bounded join; false confirmation means the host still owns cleanup.
pub async fn BoardOrchestrator::dispatch_next(
  self : BoardOrchestrator,
  planning_revision? : Int64,
) -> Result[ExecutionDispatch, OrchestrationError] {
  if self.closed {
    return Err(Closed)
  }
  if self.busy {
    return Err(Busy)
  }
  self.busy = true
  defer {
    self.busy = false
  }
  let mut admitted : @execution.BoardExecutionHandle? = None
  let result = @async.handle_cancellation(() => {
    let state = match self.owner.board_state() {
      Ok(state) => state
      Err(_) => return Err(BoardUnavailable)
    }
    let initial = self.plan_state(state, false, self.owner.status())
    if planning_revision is Some(revision) && revision != initial.revision {
      return Ok(StalePlan(initial))
    }
    let candidate = match initial.eligible.get(0) {
      Some(candidate) => candidate
      None => return Ok(Blocked(initial))
    }
    let resolution = self.resolver.resolve(candidate) catch {
      _ => return Err(ResolutionFailed)
    }
    let input = match resolution {
      Authorized(input) => input
      InputMissing => return Err(InputUnavailable)
      NotAuthorized => return Err(AuthorizationRejected)
    }
    if self.closed {
      return Err(Closed)
    }
    let fresh = match self.owner.board_state() {
      Ok(state) => self.plan_state(state, false, self.owner.status())
      Err(_) => return Err(BoardUnavailable)
    }
    if fresh.revision != initial.revision ||
      fresh.eligible.get(0) != Some(candidate) {
      return Ok(StalePlan(fresh))
    }
    let request : @execution.BoardExecutionRequest = {
      task_id: candidate.task_id,
      attempt_id: candidate.attempt_id,
      execution_id: input.execution_id,
      session_id: input.session_id,
      input: input.input,
      timeout_ms: input.timeout_ms,
    }
    match
      self.owner.execute(request, reservation_revision=fresh.revision, admission_guard=snapshot => {
        // Check again at the actual scoped model gate, before durable Start.
        // After Start, dependency changes do not cause implicit cancellation.
        !self.closed &&
        plan_execution(snapshot, self.policy, [
          {
            task_id: candidate.task_id,
            attempt_id: candidate.attempt_id,
            status: self.resolver.availability(candidate),
          },
        ]).eligible.contains(candidate)
      }) {
      Err(@execution.IneligibleAttempt) =>
        match self.owner.board_state() {
          Ok(state) =>
            Ok(StalePlan(self.plan_state(state, false, self.owner.status())))
          Err(_) => Err(BoardUnavailable)
        }
      Err(error) => Err(OwnerRejected(error))
      Ok(handle) => {
        admitted = Some(handle)
        // Deliver pending caller cancellation after the protected reservation,
        // but only once we hold the exact handle needed to cancel/join it.
        @async.pause()
        Ok(Admitted(handle))
      }
    }
  })
  match result {
    Some(result) => result
    None =>
      @async.protect_from_cancel(() => {
        let confirmed = match admitted {
          None => true
          Some(handle) => {
            ignore(self.owner.cancel(handle.execution_id()))
            @async.with_timeout(4000, () => {
              ignore(handle.wait())
              true
            }) catch {
              _ => false
            }
          }
        }
        Err(DispatchCancelled(cleanup_confirmed=confirmed))
      })
  }
}

///|
/// Cancellation request, not proof of termination. The exact owned identity is
/// mandatory; a stale UI selection or task stage cannot target another run.
pub fn BoardOrchestrator::cancel_active(
  self : BoardOrchestrator,
  execution_id : String,
) -> Result[Unit, @execution.BoardExecutionError] {
  self.owner.cancel(execution_id)
}

///|
/// Close admission and delegate owned cancellation/join. False also covers an
/// in-flight resolver/dispatch: the host must await that caller and repeat this
/// operation before releasing the journal or shutting down BoardBackend.
pub async fn BoardOrchestrator::shutdown(
  self : BoardOrchestrator,
  timeout_ms? : Int = 4000,
) -> Bool {
  self.closed = true
  let joined = self.owner.shutdown(timeout_ms~)
  joined && !self.busy
}
