///|
priv suberror ParallelDeadline

///|
priv struct Completion {
  execution_id : String
  binding : @execution.BoardExecutionBinding?
}

///|
/// One host-owned control task admits bounded waves through S4B. Only S4A
/// owns Agents and journal effects. The host must exclusively dedicate this
/// orchestrator/owner to the runner while its authorization is active.
pub struct ParallelWorkflowRunner {
  priv orchestrator : @orchestration.BoardOrchestrator
  priv group : @async.TaskGroup[Unit]
  priv now_ms : () -> Int64
  priv wake : @aqueue.Queue[Unit]
  priv completions : @aqueue.Queue[Completion]
  priv history : Array[String]
  priv handles : Array[@execution.BoardExecutionHandle]
  priv accounted : Map[String, Unit]
  priv mut spec : ParallelWorkflowSpec?
  priv mut scope : Array[String]
  priv mut worker : @async.Task[Unit]?
  priv mut phase : @workflow.WorkflowPhase
  priv mut starting : Bool
  priv mut entered : Bool
  priv mut closed : Bool
  priv mut cancel_requested : Bool
  priv mut stop_requested : Bool
  priv mut deadline_expired : Bool
  priv mut wave_failure : @execution.BoardExecutionOutcome?
  priv mut wave_unresolved : Bool
  priv mut admitted : Int32
  priv mut settled : Int32
  priv mut succeeded : Int32
  priv mut failed : Int32
  priv mut cancelled : Int32
  priv mut started_at : Int64?
  priv mut elapsed : Int64
  priv mut revision : Int64?
  priv mut blocked : Array[@orchestration.BlockedExecution]
  priv mut reason : @workflow.WorkflowStopReason?
}

///|
pub fn ParallelWorkflowRunner::ParallelWorkflowRunner(
  orchestrator~ : @orchestration.BoardOrchestrator,
  group~ : @async.TaskGroup[Unit],
  now_ms~ : () -> Int64 = @async.now,
) -> ParallelWorkflowRunner {
  {
    orchestrator,
    group,
    now_ms,
    wake: @aqueue.Queue(kind=DiscardLatest(1)),
    completions: @aqueue.Queue(kind=Blocking(8)),
    history: [],
    handles: [],
    accounted: Map([]),
    spec: None,
    scope: [],
    worker: None,
    phase: @workflow.Idle,
    starting: false,
    entered: false,
    closed: false,
    cancel_requested: false,
    stop_requested: false,
    deadline_expired: false,
    wave_failure: None,
    wave_unresolved: false,
    admitted: 0,
    settled: 0,
    succeeded: 0,
    failed: 0,
    cancelled: 0,
    started_at: None,
    elapsed: 0L,
    revision: None,
    blocked: [],
    reason: None,
  }
}

///|
fn ParallelWorkflowRunner::elapsed_ms(self : ParallelWorkflowRunner) -> Int64 {
  if self.phase is (Running | Pausing | Paused | Stopping) &&
    self.started_at is Some(start) {
    self.elapsed = self.elapsed.max(0L.max((self.now_ms)() - start))
  }
  self.elapsed
}

///|
/// Read-only, detached ID/status metadata. Owner occupancy, not planned work,
/// determines active counts; querying progress never dispatches or repairs.
pub fn ParallelWorkflowRunner::status(
  self : ParallelWorkflowRunner,
) -> ParallelWorkflowStatus {
  let elapsed = self.elapsed_ms()
  let owner = self.orchestrator.owner_status()
  let capacity = self.spec.map(spec => spec.max_concurrency).unwrap_or(1)
  let counts = block_counts(self.blocked)
  {
    run_id: self.spec.map(spec => spec.run_id),
    phase: self.phase,
    max_concurrency: capacity,
    active: owner.active_bindings.copy(),
    active_count: owner.active_bindings.length(),
    available_slots: (capacity - owner.active_bindings.length())
    .max(0)
    .min(owner.available_slots),
    admitted: self.admitted,
    settled: self.settled,
    succeeded: self.succeeded,
    failed: self.failed,
    cancelled: self.cancelled,
    remaining_executions: self.spec
    .map(spec => (spec.max_executions - self.admitted).max(0))
    .unwrap_or(0),
    started_at_ms: self.started_at,
    elapsed_ms: elapsed,
    remaining_ms: self.spec
    .map(spec => (spec.max_elapsed_ms.to_int64() - elapsed).max(0L))
    .unwrap_or(0L),
    board_revision: self.revision,
    blocked: self.blocked.map(row => { ..row, reasons: row.reasons.copy(), }),
    blocked_count: self.blocked.length(),
    blocked_reason_counts: counts,
    reason: self.reason,
  }
}

///|
fn ParallelWorkflowRunner::finish(
  self : ParallelWorkflowRunner,
  phase : @workflow.WorkflowPhase,
  reason : @workflow.WorkflowStopReason,
) -> Unit {
  ignore(self.elapsed_ms())
  self.phase = phase
  self.reason = Some(reason)
}

///|
fn ParallelWorkflowRunner::has_time(
  self : ParallelWorkflowRunner,
  spec : ParallelWorkflowSpec,
) -> Bool {
  !self.deadline_expired &&
  self.elapsed_ms() + spec.execution_timeout_ms.to_int64() <=
  spec.max_elapsed_ms.to_int64()
}

///|
/// Freeze scope and reserve one control loop before any await. Process restart
/// never restores this authorization; unresolved journal history blocks start.
pub async fn ParallelWorkflowRunner::start(
  self : ParallelWorkflowRunner,
  spec : ParallelWorkflowSpec,
) -> Result[Unit, @workflow.WorkflowError] {
  if self.closed {
    return Err(@workflow.Closed)
  }
  let owner = self.orchestrator.owner_status()
  if self.phase is Unresolved || owner.unresolved {
    return Err(@workflow.UnresolvedOwner)
  }
  if self.starting ||
    self.phase is (Running | Pausing | Paused | Stopping) ||
    !self.handles.is_empty() ||
    (self.worker.map(task => task.try_wait() is None).unwrap_or(false) catch {
      _ => true
    }) {
    return Err(@workflow.AlreadyRunning)
  }
  if !spec.validate() || spec.max_concurrency > owner.capacity {
    return Err(@workflow.InvalidSpec)
  }
  if !owner.active_bindings.is_empty() || owner.admission_busy {
    return Err(@workflow.AlreadyRunning)
  }
  if self.history.contains(spec.run_id) {
    return Err(@workflow.DuplicateRunIdentity)
  }
  let detached = {
    ..spec,
    scope: match spec.scope {
      Selected(ids) => @workflow.Selected(ids.copy())
      AllEligibleAtStart => @workflow.AllEligibleAtStart
    },
  }
  self.phase = @workflow.Running
  self.starting = true
  defer {
    self.starting = false
  }
  self.entered = false
  self.cancel_requested = false
  self.stop_requested = false
  self.deadline_expired = false
  let initialized = @async.handle_cancellation(() => {
    let state = match self.orchestrator.board_state() {
      Ok(state) => state
      Err(_) => return Err(@workflow.BoardUnavailable)
    }
    let scope = match detached.scope {
      AllEligibleAtStart => state.tasks.map(task => task.id.value)
      Selected(ids) => {
        if ids.any(id => !state.tasks.any(task => task.id.value == id)) {
          return Err(@workflow.InvalidScope)
        }
        let result : Array[String] = []
        for id in ids {
          if !result.contains(id) {
            result.push(id)
          }
        }
        result
      }
    }
    if self.closed || self.cancel_requested {
      return Err(@workflow.StartCancelled)
    }
    self.spec = Some(detached)
    self.scope = scope
    self.history.push(detached.run_id)
    self.accounted.clear()
    while self.completions.try_get() is Some(_) {

    }
    self.wave_failure = None
    self.wave_unresolved = false
    self.admitted = 0
    self.settled = 0
    self.succeeded = 0
    self.failed = 0
    self.cancelled = 0
    self.elapsed = 0L
    self.started_at = Some((self.now_ms)())
    self.revision = Some(state.revision)
    self.reason = None
    self.worker = Some(self.group.spawn(() => self.drive(detached)))
    Ok(())
  })
  match initialized {
    Some(Ok(_)) => Ok(())
    Some(Err(error)) => {
      self.finish(@workflow.Stopped, @workflow.StopRequested)
      Err(error)
    }
    None => {
      self.finish(@workflow.Stopped, @workflow.CancelRequested)
      Err(@workflow.StartCancelled)
    }
  }
}

///|
pub fn ParallelWorkflowRunner::pause(self : ParallelWorkflowRunner) -> Bool {
  if self.phase is Running {
    self.phase = @workflow.Pausing
    ignore(self.wake.try_put(()) catch { _ => false })
    true
  } else {
    false
  }
}

///|
pub fn ParallelWorkflowRunner::resume_workflow(
  self : ParallelWorkflowRunner,
) -> Bool {
  if !self.closed && self.phase is Paused {
    self.phase = @workflow.Running
    ignore(self.wake.try_put(()) catch { _ => false })
    true
  } else {
    false
  }
}

///|
pub fn ParallelWorkflowRunner::stop_after_wave(
  self : ParallelWorkflowRunner,
) -> Bool {
  if self.phase is (Running | Pausing | Paused) {
    self.stop_requested = true
    self.phase = @workflow.Stopping
    ignore(self.wake.try_put(()) catch { _ => false })
    true
  } else {
    false
  }
}

///|
fn ParallelWorkflowRunner::cancel_handles(
  self : ParallelWorkflowRunner,
) -> Unit {
  // The exclusively dedicated owner may already have reserved the current
  // dispatch while its protected handle delivery is still in flight.
  for binding in self.orchestrator.owner_status().active_bindings {
    ignore(self.orchestrator.cancel_active(binding.execution_id))
  }
  for handle in self.handles {
    ignore(self.orchestrator.cancel_active(handle.execution_id()))
  }
}

///|
/// Stops admission first; requests exact cancellation for every admitted run.
/// An acknowledgement never counts as termination or durable settlement.
pub fn ParallelWorkflowRunner::cancel(self : ParallelWorkflowRunner) -> Unit {
  if self.phase is (Running | Pausing | Paused | Stopping) {
    self.cancel_requested = true
    self.phase = @workflow.Stopping
    self.cancel_handles()
    if self.entered && self.worker is Some(worker) {
      worker.cancel()
    }
    ignore(self.wake.try_put(()) catch { _ => false })
  }
}

///|
pub async fn ParallelWorkflowRunner::wait(
  self : ParallelWorkflowRunner,
) -> ParallelWorkflowStatus {
  if self.worker is Some(worker) {
    worker.wait()
  }
  self.status()
}
