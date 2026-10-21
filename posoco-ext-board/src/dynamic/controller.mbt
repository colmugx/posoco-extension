///|
/// Trusted-headless composition. The host dedicates this exact owner/backend
/// and its journal to the controller; no competing direct admissions are allowed.
pub struct DynamicWorkflowController {
  priv backend : @backend.BoardBackend
  priv owner : @execution.BoardExecutionOwner
  priv orchestrator : @orchestration.BoardOrchestrator
  priv runner : @parallel.ParallelWorkflowRunner
  priv group : @async.TaskGroup[Unit]
  priv spec : DynamicWorkflowSpec
  priv policy : @expansion.ExpansionPolicy
  priv now_ms : () -> Int64
  priv mut started : Bool
  priv mut starting : Bool
  priv mut closed : Bool
  priv mut cancel_requested : Bool
  priv mut host_paused : Bool
  priv mut busy : Bool
  priv mut operation : @async.Task[Unit]?
  priv mut unresolved : Bool
  priv mut op : @expansion.ExpansionHost?
  priv mut uncertain : @expansion.ExpansionHost?
  priv mut planning_active : Bool
  priv mut expansions_attempted : Int32
  priv mut reservations : Int32
  priv mut expansions_committed : Int32
  priv mut generated_tasks_committed : Int32
  priv mut scope_authorizations : Int32
  priv authorized : Map[String, Array[String]]
  priv used_authorities : Set[String]
  priv mut last_expansion_phase : @expansion.ExpansionPhase?
  priv mut pending_id : String?
  priv mut last_id : String?
  priv mut revision : Int64?
  priv mut blocked : Array[@orchestration.BlockedExecution]
  priv partials : Array[PreparationRecord]
}

///|
pub fn DynamicWorkflowController::create(
  owner~ : @execution.BoardExecutionOwner,
  backend~ : @backend.BoardBackend,
  resolver~ : &@orchestration.BoardExecutionInputResolver,
  group~ : @async.TaskGroup[Unit],
  spec~ : DynamicWorkflowSpec,
  now_ms~ : () -> Int64 = @async.now,
) -> Result[DynamicWorkflowController, DynamicWorkflowError] {
  if !spec.validate() {
    return Err(InvalidSpec)
  }
  if !owner.uses_backend(backend) {
    return Err(BackendMismatch)
  }
  let policy = match spec.expansion {
    None => @expansion.ExpansionPolicy()
    Some(expansion) =>
      @expansion.ExpansionPolicy(
        max_workflow_expansions=expansion.max_expansions,
        max_workflow_tasks=expansion.max_generated_tasks,
        max_depth=expansion.max_depth,
      )
  }
  let orchestrator = @orchestration.BoardOrchestrator(
    owner~,
    resolver~,
    policy=@orchestration.ExecutionPolicy(enabled=true),
  )
  let runner = @parallel.ParallelWorkflowRunner(orchestrator~, group~, now_ms~)
  Ok({
    backend,
    owner,
    orchestrator,
    runner,
    group,
    spec: { ..spec, initial_scope: spec.initial_scope.copy(), },
    policy,
    now_ms,
    started: false,
    starting: false,
    closed: false,
    cancel_requested: false,
    host_paused: false,
    busy: false,
    operation: None,
    unresolved: false,
    op: None,
    uncertain: None,
    planning_active: false,
    expansions_attempted: 0,
    reservations: 0,
    expansions_committed: 0,
    generated_tasks_committed: 0,
    scope_authorizations: 0,
    authorized: Map([]),
    used_authorities: Set([]),
    last_expansion_phase: None,
    pending_id: None,
    last_id: None,
    revision: None,
    blocked: [],
    partials: [],
  })
}

///|
fn DynamicWorkflowController::gate(
  self : DynamicWorkflowController,
) -> Result[Unit, DynamicWorkflowError] {
  if self.closed || self.cancel_requested {
    return Err(Closed)
  }
  if !self.started {
    return Err(NotStarted)
  }
  if self.host_paused {
    return Err(HostPaused)
  }
  let status = self.runner.status()
  if self.unresolved ||
    status.phase is Unresolved ||
    self.owner.status().unresolved {
    return Err(RunnerRejected(@workflow.UnresolvedOwner))
  }
  if status.remaining_ms <= 0L {
    return Err(BudgetExceeded)
  }
  if !(status.phase is (Running | Pausing | Paused)) {
    return Err(Closed)
  }
  Ok(())
}

///|
fn DynamicWorkflowController::at_boundary(
  self : DynamicWorkflowController,
) -> Result[Unit, DynamicWorkflowError] {
  match self.gate() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if !self.runner.quiescent() {
    return Err(NotQuiescent)
  }
  Ok(())
}

///|
/// One cancellable, deadline-bounded operation, separate from S4D's wave task.
/// A failed join keeps ownership and fails shutdown closed.
async fn[T] DynamicWorkflowController::perform(
  self : DynamicWorkflowController,
  work : async () -> Result[T, DynamicWorkflowError],
  recovery~ : Bool = false,
) -> Result[T, DynamicWorkflowError] {
  if self.closed {
    return Err(Closed)
  }
  if self.busy {
    return Err(Busy)
  }
  if !recovery {
    match self.gate() {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  self.busy = true
  let result : Ref[Result[T, DynamicWorkflowError]?] = Ref(None)
  let timeout = if recovery {
    4000
  } else {
    self.runner.status().remaining_ms.max(1L).to_int()
  }
  let task = self.group.spawn(allow_failure=true, () => {
    result.val = Some(@async.with_timeout(timeout, work))
  })
  self.operation = Some(task)
  let waited = @async.handle_cancellation(() => {
    task.wait()
    true
  }) catch {
    _ => Some(false)
  }
  if waited != Some(true) {
    task.cancel()
    let joined = @async.protect_from_cancel(() => join_operation(task, 4000))
    if !joined {
      self.unresolved = true
      return Err(OperationInterrupted)
    }
  }
  self.operation = None
  self.busy = false
  result.val.unwrap_or(Err(OperationInterrupted))
}

///|
pub async fn DynamicWorkflowController::start(
  self : DynamicWorkflowController,
) -> Result[Unit, DynamicWorkflowError] {
  if self.closed || self.cancel_requested {
    return Err(Closed)
  }
  if self.started || self.starting {
    return Err(AlreadyStarted)
  }
  self.starting = true
  defer {
    self.starting = false
  }
  let result = self.runner.start_controlled(
    @parallel.ParallelWorkflowSpec(
      run_id=self.spec.workflow_id,
      scope=@workflow.Selected(self.spec.initial_scope),
      max_executions=self.spec.max_executions,
      max_elapsed_ms=self.spec.max_elapsed_ms,
      execution_timeout_ms=self.spec.execution_timeout_ms,
      max_concurrency=self.spec.max_concurrency,
      failure_policy=self.spec.failure_policy,
    ),
  )
  match result {
    Err(e) => return Err(RunnerRejected(e))
    Ok(_) => ()
  }
  self.started = true
  let snapshot = match self.backend.state() {
    Ok(s) => s
    Err(_) => {
      self.cancel()
      return Err(BoardUnavailable)
    }
  }
  self.observe(snapshot)
  self.reservations = self.expansions_committed
  if self.cancel_requested || self.closed {
    self.runner.cancel()
    return Err(Closed)
  }
  self.refresh_status().map(_ => ())
}

///|
fn DynamicWorkflowController::observe(
  self : DynamicWorkflowController,
  snapshot : @domain.BoardStateSnapshot,
) -> Unit {
  self.revision = Some(snapshot.revision)
  let records = snapshot.expansions.filter(r => {
    r.workflow_id == self.spec.workflow_id
  })
  self.expansions_committed = records.length()
  self.generated_tasks_committed = records.fold(init=0, (n, r) => {
    n + r.mapping.length()
  })
}

///|
/// Cached observation; use refresh_status for a fresh authoritative plan.
pub fn DynamicWorkflowController::status(
  self : DynamicWorkflowController,
) -> DynamicWorkflowStatus {
  let runner = self.runner.status()
  {
    workflow_id: self.spec.workflow_id,
    phase: runner.phase,
    reason: runner.reason,
    runner,
    scope: self.runner.authorized_scope(),
    scope_authorizations: self.scope_authorizations,
    expansions_attempted: self.expansions_attempted,
    expansions_committed: self.expansions_committed,
    generated_tasks_committed: self.generated_tasks_committed,
    expansion_enabled: self.spec.expansion is Some(_),
    expansion_phase: match self.op {
      Some(h) => Some(h.phase())
      None => self.last_expansion_phase
    },
    planning_active: self.planning_active,
    partial_preparations: self.partials.copy(),
    board_revision: self.revision,
    blocked: self.blocked.map(r => { ..r, reasons: r.reasons.copy(), }),
    pending_proposal_id: self.pending_id,
    last_committed_expansion_id: self.last_id,
    host_paused: self.host_paused,
    operation_active: self.busy,
    unresolved: self.unresolved ||
    runner.phase is Unresolved ||
    self.owner.status().unresolved,
    remaining_expansions: self.spec.expansion
    .map(e => {
      (e.max_expansions - self.reservations.max(self.expansions_committed)).max(
        0,
      )
    })
    .unwrap_or(0),
    remaining_generated_tasks: self.spec.expansion
    .map(e => (e.max_generated_tasks - self.generated_tasks_committed).max(0))
    .unwrap_or(0),
  }
}

///|
pub async fn DynamicWorkflowController::refresh_status(
  self : DynamicWorkflowController,
) -> Result[DynamicWorkflowStatus, DynamicWorkflowError] {
  let snapshot = match self.backend.state() {
    Ok(s) => s
    Err(_) => return Err(BoardUnavailable)
  }
  self.observe(snapshot)
  let plan = match
    self.orchestrator.plan(task_scope=self.runner.authorized_scope()) {
    Ok(plan) => plan
    Err(_) => return Err(BoardUnavailable)
  }
  self.revision = Some(plan.revision)
  self.blocked = plan.blocked
  Ok(self.status())
}

///|
pub fn DynamicWorkflowController::pause(
  self : DynamicWorkflowController,
) -> Bool {
  if !self.started || self.closed || self.cancel_requested {
    return false
  }
  self.host_paused = true
  if self.operation is Some(task) {
    task.cancel()
  }
  ignore(self.runner.pause())
  if !self.busy {
    self.discard_proposal()
  }
  true
}

///|
/// Clears a host pause in process only; it does not dispatch a wave or restore
/// a discarded approval. The host separately calls run_wave.
pub async fn DynamicWorkflowController::resume_workflow(
  self : DynamicWorkflowController,
) -> Result[Unit, DynamicWorkflowError] {
  if self.closed || self.cancel_requested {
    return Err(Closed)
  }
  if !self.started {
    return Err(NotStarted)
  }
  if self.busy || self.uncertain is Some(_) {
    return Err(Busy)
  }
  match self.refresh_status() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if !self.runner.quiescent() {
    return Err(NotQuiescent)
  }
  let was_paused = self.host_paused
  self.host_paused = false
  let result = self.gate()
  if result is Err(_) {
    self.host_paused = was_paused
  }
  result
}

///|
pub async fn DynamicWorkflowController::run_wave(
  self : DynamicWorkflowController,
) -> Result[Unit, DynamicWorkflowError] {
  if self.busy || self.op is Some(_) || self.uncertain is Some(_) {
    return Err(Busy)
  }
  match self.at_boundary() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if self.partials.any(r => r.uncertain) {
    return Err(PreparationBlocked)
  }
  match self.refresh_status() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  match self.at_boundary() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if !self.runner.resume_workflow() {
    return Err(NotQuiescent)
  }
  Ok(())
}

///|
/// Run one controlled wave through an exact host-authorized Task subset. The
/// transient admission restriction remains active until clear_control_scope,
/// which the joined host operation must call in a defer.
pub async fn DynamicWorkflowController::run_wave_scoped(
  self : DynamicWorkflowController,
  candidates : Array[@orchestration.ExecutionCandidate],
  authorize~ : () -> Bool,
) -> Result[Unit, DynamicWorkflowError] {
  let scope = self.runner.authorized_scope()
  if candidates.any(c => !scope.contains(c.task_id)) ||
    !self.orchestrator.set_control_scope(
      Some(candidates),
      authorize~,
    ) {
    return Err(TaskOutOfScope)
  }
  if self.busy || self.op is Some(_) || self.uncertain is Some(_) {
    ignore(self.orchestrator.set_control_scope(None, authorize=() => true))
    return Err(Busy)
  }
  match self.at_boundary() {
    Err(e) => {
      ignore(self.orchestrator.set_control_scope(None, authorize=() => true))
      return Err(e)
    }
    Ok(_) => ()
  }
  if self.partials.any(r => r.uncertain) {
    ignore(self.orchestrator.set_control_scope(None, authorize=() => true))
    return Err(PreparationBlocked)
  }
  match self.refresh_status() {
    Err(e) => {
      ignore(self.orchestrator.set_control_scope(None, authorize=() => true))
      return Err(e)
    }
    Ok(_) => ()
  }
  match self.at_boundary() {
    Err(e) => {
      ignore(self.orchestrator.set_control_scope(None, authorize=() => true))
      return Err(e)
    }
    Ok(_) => ()
  }
  if !self.runner.resume_workflow() {
    ignore(self.orchestrator.set_control_scope(None, authorize=() => true))
    return Err(NotQuiescent)
  }
  Ok(())
}

///|
/// Read the existing planner; this does not reserve or dispatch an Attempt.
pub async fn DynamicWorkflowController::execution_plan(
  self : DynamicWorkflowController,
  task_ids : Array[String],
) -> Result[@orchestration.ExecutionPlan, DynamicWorkflowError] {
  match self.at_boundary() {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if task_ids.any(id => !self.runner.authorized_scope().contains(id)) {
    return Err(TaskOutOfScope)
  }
  match self.orchestrator.plan(task_scope=task_ids.copy()) {
    Ok(plan) => Ok(plan)
    Err(_) => Err(BoardUnavailable)
  }
}

///|
pub fn DynamicWorkflowController::clear_control_scope(
  self : DynamicWorkflowController,
) -> Unit {
  ignore(self.orchestrator.set_control_scope(None, authorize=() => true))
}

///|
pub async fn DynamicWorkflowController::wait_boundary(
  self : DynamicWorkflowController,
) -> Result[DynamicWorkflowStatus, DynamicWorkflowError] {
  if !self.started {
    return Err(NotStarted)
  }
  let timeout = self.runner.status().remaining_ms.max(1L).to_int() + 4000
  let joined = @async.with_timeout(timeout, () => {
    @async.pause()
    while self.busy ||
          self.planning_active ||
          !self.owner.status().active_bindings.is_empty() ||
          self.runner.status().phase is (Running | Pausing | Stopping) {
      if self.unresolved {
        return false
      }
      @async.sleep(1)
    }
    true
  }) catch {
    _ => false
  }
  if !joined {
    return Err(OperationInterrupted)
  }
  self.refresh_status()
}

///|
pub fn DynamicWorkflowController::cancel(
  self : DynamicWorkflowController,
) -> Unit {
  self.cancel_requested = true
  if self.operation is Some(task) {
    task.cancel()
  }
  self.runner.cancel()
  if !self.busy {
    self.discard_proposal()
  }
}

///|
/// Never discard a commit in flight or its uncertain identity.
pub fn DynamicWorkflowController::discard_proposal(
  self : DynamicWorkflowController,
) -> Unit {
  if self.busy {
    return
  }
  if self.op is Some(host) {
    if host.phase() is (CommitRequested | Uncertain) {
      return
    }
    self.last_expansion_phase = Some(host.phase())
    self.op = None
    self.pending_id = None
  }
}

///|
pub async fn DynamicWorkflowController::wait(
  self : DynamicWorkflowController,
) -> DynamicWorkflowStatus {
  ignore(self.runner.wait())
  self.status()
}

///|
/// Cancels/joins operations and S4D/S4A before permitting backend/lock teardown.
/// A frozen graph identity is retained even when this returns true.
pub async fn DynamicWorkflowController::quiesce(
  self : DynamicWorkflowController,
  timeout_ms~ : Int32 = 4000,
) -> Bool {
  self.closed = true
  self.cancel()
  if timeout_ms <= 0 {
    return false
  }
  let start = @async.now()
  if self.operation is Some(task) {
    let joined = join_operation(task, timeout_ms)
    if !joined {
      return false
    }
  }
  if self.starting ||
    self.planning_active ||
    self.unresolved ||
    self.owner.status().unresolved ||
    self.runner.status().phase is Unresolved {
    return false
  }
  let remaining = (timeout_ms.to_int64() - (@async.now() - start))
    .max(1L)
    .to_int()
  if !self.runner.shutdown(timeout_ms=remaining) {
    return false
  }
  true
}

///|
/// Final teardown for direct headless hosts. Composed extensions quiesce,
/// release their journal lock, then close their owned backend last.
pub async fn DynamicWorkflowController::shutdown(
  self : DynamicWorkflowController,
  timeout_ms~ : Int32 = 4000,
) -> Bool {
  let start = @async.now()
  if !self.quiesce(timeout_ms~) {
    return false
  }
  let left = (timeout_ms.to_int64() - (@async.now() - start)).max(1L).to_int()
  @async.with_timeout(left, () => {
    self.backend.shutdown()
    true
  }) catch {
    _ => false
  }
}

///|
/// Waiting may report a failed or cancelled operation, both of which prove
/// termination. Its failure is returned by perform; this helper proves join
/// only. A timeout, unlike a task failure, never proves termination.
async fn join_operation(task : @async.Task[Unit], timeout : Int32) -> Bool {
  @async.with_timeout(timeout, () => {
    task.wait() catch {
      _ => ()
    }
    true
  }) catch {
    _ => false
  }
}
