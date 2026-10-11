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
/// Nonblocking owner facts for cancellation/settlement inspection even when
/// Board reads are unavailable. This is neither admission nor a joined handle.
pub fn BoardOrchestrator::owner_status(
  self : BoardOrchestrator,
) -> @execution.BoardExecutionOwnerStatus {
  self.owner.status()
}

///|
fn BoardOrchestrator::plan_state(
  self : BoardOrchestrator,
  state : @domain.BoardStateSnapshot,
  include_dispatch_busy : Bool,
  status : @execution.BoardExecutionOwnerStatus,
  task_scope : Array[String]?,
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
  scope_filter({ ..plan, eligible, blocked, }, task_scope)
}

///|
/// A present scope authorizes only its listed Task IDs; an empty scope
/// authorizes nothing. Dependencies outside the scope still gate scoped tasks
/// because plan_execution always sees the full snapshot. The plan arrays are
/// freshly built per call, so filtering detaches them again.
fn scope_filter(
  plan : ExecutionPlan,
  task_scope : Array[String]?,
) -> ExecutionPlan {
  match task_scope {
    None => plan
    Some(ids) => {
      let eligible = plan.eligible.filter(candidate => {
        ids.contains(candidate.task_id)
      })
      let blocked = plan.blocked.filter(row => ids.contains(row.task_id))
      { ..plan, eligible, blocked, }
    }
  }
}

///|
/// The effective request timeout is the resolver timeout capped to the caller
/// ceiling; a ceiling alone also bounds a resolver that supplies no timeout.
fn capped_timeout(resolver_ms : Int?, ceiling_ms : Int?) -> Int? {
  match ceiling_ms {
    None => resolver_ms
    Some(cap) =>
      match resolver_ms {
        None => Some(cap)
        Some(ms) => Some(if ms < cap { ms } else { cap })
      }
  }
}

///|
/// Pure planning plus live owner/input metadata inspection. No IDs reserved,
/// no input retained, no execution started. The result can become stale at once.
/// An omitted `task_scope` plans every Task (S4B); a present one detaches from
/// the caller's array and authorizes only its Task IDs.
pub async fn BoardOrchestrator::plan(
  self : BoardOrchestrator,
  task_scope? : Array[String],
) -> Result[ExecutionPlan, OrchestrationError] {
  let scope = task_scope.map(ids => ids.copy())
  match self.owner.board_state() {
    Ok(state) => Ok(self.plan_state(state, true, self.owner.status(), scope))
    Err(_) => Err(BoardUnavailable)
  }
}

///|
/// Read-only operational status; active is actual owner metadata, never inferred
/// from a Task stage. Prompts and provider output are absent. An omitted
/// `task_scope` plans every Task (S4B); a present one detaches from the
/// caller's array and authorizes only its Task IDs.
pub async fn BoardOrchestrator::status(
  self : BoardOrchestrator,
  task_scope? : Array[String],
) -> Result[OrchestrationStatus, OrchestrationError] {
  let scope = task_scope.map(ids => ids.copy())
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
        plan: self.plan_state(state, true, owner, scope),
      })
    }
    Err(_) => Err(BoardUnavailable)
  }
}

///|
/// Detached snapshot from the same owner this facade plans and dispatches
/// through, so runner start scope validation cannot read a different Board and
/// cannot mutate this one. It is an inspection, not a reservation.
pub async fn BoardOrchestrator::board_state(
  self : BoardOrchestrator,
) -> Result[@domain.BoardStateSnapshot, OrchestrationError] {
  match self.owner.board_state() {
    Ok(state) => Ok(state.copy_detached())
    Err(_) => Err(BoardUnavailable)
  }
}

///|
/// One explicit call admits at most one run. Resolve is cancellable and must not
/// execute work. Revision changes during resolution return a fresh StalePlan,
/// requiring new host intent. No automatic selection fallback, replay or retry.
/// Cancellation after journal reservation requests exact-run cancellation and
/// bounded join; false confirmation means the host still owns cleanup.
///
/// An omitted `task_scope` authorizes every Task (S4B); a present one detaches
/// from the caller's array, filters the plan and the first-candidate selection
/// and revalidates the same scope after resolution. A nonpositive
/// `execution_timeout_ms` ceiling is a safe InvalidDispatch before any effect;
/// otherwise it caps the resolver timeout and bounds runs that supply none.
/// `admission_guard` defaults to true and is rechecked before resolution, after
/// resolution, at the owner's protected reservation and at the actual model
/// gate. A false result before admission returns AdmissionStopped with no
/// reservation and no effect; a false result at the model gate prevents
/// provider effects on the already admitted exact run.
pub async fn BoardOrchestrator::dispatch_next(
  self : BoardOrchestrator,
  planning_revision? : Int64,
  task_scope? : Array[String],
  admission_guard? : () -> Bool = () => true,
  execution_timeout_ms? : Int,
) -> Result[ExecutionDispatch, OrchestrationError] {
  if execution_timeout_ms is Some(ms) && ms <= 0 {
    return Err(InvalidDispatch)
  }
  if self.closed {
    return Err(Closed)
  }
  if self.busy {
    return Err(Busy)
  }
  // The scope is detached once per call, so later caller mutations cannot
  // change an in-flight dispatch.
  let scope = task_scope.map(ids => ids.copy())
  self.busy = true
  defer {
    self.busy = false
  }
  let mut admitted : @execution.BoardExecutionHandle? = None
  let mut stopped = false
  let result = @async.handle_cancellation(() => {
    if !admission_guard() {
      return Err(AdmissionStopped)
    }
    let state = match self.owner.board_state() {
      Ok(state) => state
      Err(_) => return Err(BoardUnavailable)
    }
    let initial = self.plan_state(state, false, self.owner.status(), scope)
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
    if !admission_guard() {
      return Err(AdmissionStopped)
    }
    let fresh = match self.owner.board_state() {
      Ok(state) => self.plan_state(state, false, self.owner.status(), scope)
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
      timeout_ms: capped_timeout(input.timeout_ms, execution_timeout_ms),
    }
    match
      self.owner.execute(request, reservation_revision=fresh.revision, admission_guard=snapshot => {
        // Recheck the caller guard at the actual scoped model gate, before
        // durable Start. After Start, dependency changes do not cause implicit
        // cancellation. The owner invokes this guard at its protected
        // reservation and again at the gate, both before provider effects.
        let authorized = admission_guard()
        let selected = authorized &&
          !self.closed &&
          plan_execution(snapshot, self.policy, [
            {
              task_id: candidate.task_id,
              attempt_id: candidate.attempt_id,
              status: self.resolver.availability(candidate),
            },
          ]).eligible.contains(candidate)
        if !authorized {
          stopped = true
        }
        selected
      }) {
      Err(@execution.IneligibleAttempt) =>
        if stopped {
          Err(AdmissionStopped)
        } else {
          match self.owner.board_state() {
            Ok(state) =>
              Ok(
                StalePlan(
                  self.plan_state(state, false, self.owner.status(), scope),
                ),
              )
            Err(_) => Err(BoardUnavailable)
          }
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
