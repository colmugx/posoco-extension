///|
priv suberror WorkflowDeadline

///|
/// One host-scope task sequences S4B dispatches. No Agent, Board mutation,
/// execution journal or background discovery loop is owned here.
pub struct SequentialWorkflowRunner {
  priv orchestrator : @orchestration.BoardOrchestrator
  priv group : @async.TaskGroup[Unit]
  priv now_ms : () -> Int64
  priv wake : @aqueue.Queue[Unit]
  priv history : Array[String]
  priv mut spec : WorkflowRunSpec?
  priv mut scope : Array[String]
  priv mut worker : @async.Task[Unit]?
  priv mut active : @execution.BoardExecutionHandle?
  priv mut phase : WorkflowPhase
  priv mut closed : Bool
  priv mut starting : Bool
  priv mut worker_entered : Bool
  priv mut deadline_expired : Bool
  priv mut cancel_requested : Bool
  priv mut stop_requested : Bool
  priv mut admitted : Int32
  priv mut succeeded : Int32
  priv mut failed : Int32
  priv mut cancelled : Int32
  priv mut started_at : Int64?
  priv mut elapsed : Int64
  priv mut current : @orchestration.ExecutionCandidate?
  priv mut revision : Int64?
  priv mut reason : WorkflowStopReason?
}

///|
/// Construct inside the SAME structured host lifetime as the S4A owner. The
/// constructor does not admit work. Shutdown must precede journal release and
/// backend shutdown, and a false shutdown result must never be ignored.
pub fn SequentialWorkflowRunner::SequentialWorkflowRunner(
  orchestrator~ : @orchestration.BoardOrchestrator,
  group~ : @async.TaskGroup[Unit],
  now_ms~ : () -> Int64 = @async.now,
) -> SequentialWorkflowRunner {
  {
    orchestrator,
    group,
    now_ms,
    wake: @aqueue.Queue(kind=DiscardLatest(1)),
    history: [],
    spec: None,
    scope: [],
    worker: None,
    active: None,
    phase: Idle,
    closed: false,
    starting: false,
    worker_entered: false,
    deadline_expired: false,
    cancel_requested: false,
    stop_requested: false,
    admitted: 0,
    succeeded: 0,
    failed: 0,
    cancelled: 0,
    started_at: None,
    elapsed: 0L,
    current: None,
    revision: None,
    reason: None,
  }
}

///|
fn SequentialWorkflowRunner::elapsed_ms(
  self : SequentialWorkflowRunner,
) -> Int64 {
  if self.phase is (Running | Pausing | Paused | Stopping) &&
    self.started_at is Some(start) {
    // A wall-clock rollback must not replenish a consumed budget. A structured
    // duration timer independently bounds the whole loop, including pauses.
    self.elapsed = self.elapsed.max(0L.max((self.now_ms)() - start))
  }
  self.elapsed
}

///|
pub fn SequentialWorkflowRunner::status(
  self : SequentialWorkflowRunner,
) -> WorkflowStatus {
  let elapsed = self.elapsed_ms()
  let remaining_ms = match self.spec {
    Some(spec) => 0L.max(spec.max_elapsed_ms.to_int64() - elapsed)
    None => 0L
  }
  {
    run_id: self.spec.map(spec => spec.run_id),
    phase: self.phase,
    admitted: self.admitted,
    succeeded: self.succeeded,
    failed: self.failed,
    cancelled: self.cancelled,
    remaining_executions: self.spec
    .map(spec => (0).max(spec.max_executions - self.admitted))
    .unwrap_or(0),
    started_at_ms: self.started_at,
    elapsed_ms: elapsed,
    remaining_ms,
    current: self.current,
    execution_id: self.active.map(handle => handle.execution_id()),
    board_revision: self.revision,
    reason: self.reason,
  }
}

///|
fn SequentialWorkflowRunner::finish(
  self : SequentialWorkflowRunner,
  phase : WorkflowPhase,
  reason : WorkflowStopReason,
) -> Unit {
  ignore(self.elapsed_ms())
  self.phase = phase
  self.reason = Some(reason)
}

///|
fn SequentialWorkflowRunner::has_time(
  self : SequentialWorkflowRunner,
  spec : WorkflowRunSpec,
) -> Bool {
  self.elapsed_ms() + spec.execution_timeout_ms.to_int64() <=
  spec.max_elapsed_ms.to_int64()
}

///|
/// One explicit authorization creates one loop. Task IDs and budgets are copied;
/// a reused in-process run identity is rejected. Restart needs NEW authorization.
pub async fn SequentialWorkflowRunner::start(
  self : SequentialWorkflowRunner,
  spec : WorkflowRunSpec,
) -> Result[Unit, WorkflowError] {
  if self.closed {
    return Err(Closed)
  }
  if self.phase is Unresolved {
    return Err(UnresolvedOwner)
  }
  if self.phase is (Running | Pausing | Paused | Stopping) ||
    self.active is Some(_) {
    return Err(AlreadyRunning)
  }
  if self.starting ||
    (self.worker.map(worker => worker.try_wait() is None).unwrap_or(false) catch {
      _ => true
    }) {
    return Err(AlreadyRunning)
  }
  if !spec.validate() {
    return Err(InvalidSpec)
  }
  if self.history.contains(spec.run_id) {
    return Err(DuplicateRunIdentity)
  }
  let detached = {
    ..spec,
    scope: match spec.scope {
      Selected(ids) => Selected(ids.copy())
      AllEligibleAtStart => AllEligibleAtStart
    },
  }
  // Reserve the loop synchronously before the first await, including startup IO.
  self.phase = Running
  self.starting = true
  defer {
    self.starting = false
  }
  self.worker_entered = false
  self.deadline_expired = false
  self.stop_requested = false
  self.cancel_requested = false
  let initialized = @async.handle_cancellation(() => {
    let state = match self.orchestrator.board_state() {
      Ok(state) => state
      Err(_) => return Err(BoardUnavailable)
    }
    let scope = match detached.scope {
      AllEligibleAtStart => state.tasks.map(task => task.id.value)
      Selected(ids) => {
        if ids.any(id => !state.tasks.any(task => task.id.value == id)) {
          return Err(InvalidScope)
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
      return Err(StartCancelled)
    }
    self.spec = Some(detached)
    self.scope = scope
    self.history.push(detached.run_id)
    self.admitted = 0
    self.succeeded = 0
    self.failed = 0
    self.cancelled = 0
    self.elapsed = 0L
    self.started_at = Some((self.now_ms)())
    self.reason = None
    self.current = None
    self.revision = Some(state.revision)
    self.worker = Some(self.group.spawn(() => self.drive(detached)))
    Ok(())
  })
  match initialized {
    Some(Ok(_)) => Ok(())
    Some(Err(error)) => {
      self.finish(Stopped, StopRequested)
      Err(error)
    }
    None => {
      self.finish(Stopped, CancelRequested)
      Err(StartCancelled)
    }
  }
}

///|
/// No new admission; an already admitted execution is allowed to settle first.
pub fn SequentialWorkflowRunner::pause(self : SequentialWorkflowRunner) -> Bool {
  if self.phase is Running {
    self.phase = Pausing
    ignore(self.wake.try_put(()) catch { _ => false })
    true
  } else {
    false
  }
}

///|
/// In-process only. The loop checks fresh eligibility and unchanged budgets.
pub fn SequentialWorkflowRunner::resume_workflow(
  self : SequentialWorkflowRunner,
) -> Bool {
  if !self.closed && self.phase is Paused {
    self.phase = Running
    ignore(self.wake.try_put(()) catch { _ => false })
    true
  } else {
    false
  }
}

///|
pub fn SequentialWorkflowRunner::stop_after_current(
  self : SequentialWorkflowRunner,
) -> Bool {
  if self.phase is (Running | Pausing | Paused) {
    self.stop_requested = true
    self.phase = Stopping
    ignore(self.wake.try_put(()) catch { _ => false })
    true
  } else {
    false
  }
}

///|
/// Requests exact owned cancellation; acknowledgement is NOT confirmed cleanup.
pub fn SequentialWorkflowRunner::cancel(
  self : SequentialWorkflowRunner,
) -> Unit {
  if self.phase is (Running | Pausing | Paused | Stopping) {
    self.cancel_requested = true
    self.phase = Stopping
    if self.active is Some(handle) {
      ignore(self.orchestrator.cancel_active(handle.execution_id()))
    }
    if self.worker_entered && self.worker is Some(worker) {
      worker.cancel()
    }
    ignore(self.wake.try_put(()) catch { _ => false })
  }
}

///|
/// Wait for the loop's cleanup attempt. Unresolved means lifetime ownership must
/// be retained even after this returns; consult shutdown's confirmed result.
pub async fn SequentialWorkflowRunner::wait(
  self : SequentialWorkflowRunner,
) -> WorkflowStatus {
  if self.worker is Some(worker) {
    worker.wait()
  }
  self.status()
}

///|
fn SequentialWorkflowRunner::record(
  self : SequentialWorkflowRunner,
  binding : @execution.BoardExecutionBinding,
) -> Bool {
  if binding.phase != @execution.Settled {
    self.finish(Unresolved, UnconfirmedSettlement)
    return false
  }
  self.active = None
  self.current = None
  match binding.outcome {
    Some(@execution.Completed) => self.succeeded += 1
    Some(@execution.Cancelled) => self.cancelled += 1
    Some(@execution.Failed | @execution.TimedOut | @execution.Interrupted) =>
      self.failed += 1
    None => {
      self.finish(Unresolved, UnconfirmedSettlement)
      return false
    }
  }
  true
}

///|
async fn SequentialWorkflowRunner::cleanup(
  self : SequentialWorkflowRunner,
) -> Bool {
  match self.active {
    None => self.phase != Unresolved
    Some(handle) => {
      ignore(self.orchestrator.cancel_active(handle.execution_id()))
      let binding = try @async.with_timeout(4000, () => handle.wait()) catch {
        _ => None
      } noraise {
        binding => Some(binding)
      }
      match binding {
        Some(binding) => self.record(binding)
        None => {
          self.finish(Unresolved, UnconfirmedSettlement)
          false
        }
      }
    }
  }
}

///|
async fn SequentialWorkflowRunner::drive(
  self : SequentialWorkflowRunner,
  spec : WorkflowRunSpec,
) -> Unit {
  self.worker_entered = true
  let remaining = (spec.max_elapsed_ms.to_int64() - self.elapsed_ms())
    .max(1L)
    .to_int()
  let completed = @async.handle_cancellation(() => {
    @async.with_task_group(deadline_scope => {
      deadline_scope.spawn_bg(no_wait=true, () => {
        @async.sleep(remaining)
        // Withdraw admission before cancellation is delivered through protected
        // reservation IO, including if the wall clock moved backwards.
        self.deadline_expired = true
        raise WorkflowDeadline
      })
      self.run_loop(spec)
    }) catch {
      WorkflowDeadline =>
        if self.phase != Unresolved {
          self.finish(Stopped, DeadlineReached)
        }
      _ =>
        if self.phase != Unresolved {
          self.finish(Failed, UnexpectedFailure)
        }
    }
  })
  @async.protect_from_cancel(() => {
    if completed is None && self.phase != Unresolved {
      self.finish(
        Stopped,
        if self.closed {
          HostShutdown
        } else {
          CancelRequested
        },
      )
    }
    if self.active is Some(_) {
      let reason = self.reason
      if self.cleanup() {
        self.reason = reason
      }
    }
    if self.phase is (Running | Pausing | Paused | Stopping) ||
      self.orchestrator.owner_status().unresolved {
      self.finish(Unresolved, UnconfirmedSettlement)
    }
  })
}

///|
async fn SequentialWorkflowRunner::run_loop(
  self : SequentialWorkflowRunner,
  spec : WorkflowRunSpec,
) -> Unit {
  let mut stale = 0
  while true {
    @async.pause()
    if self.cancel_requested || self.closed {
      self.finish(
        Stopped,
        if self.closed {
          HostShutdown
        } else {
          CancelRequested
        },
      )
      return
    }
    if self.stop_requested {
      self.finish(Stopped, StopRequested)
      return
    }
    if self.admitted >= spec.max_executions {
      self.finish(Completed, ExecutionBudgetReached)
      return
    }
    if !self.has_time(spec) {
      self.finish(Completed, InsufficientTime)
      return
    }
    if self.phase is Pausing {
      self.phase = Paused
    }
    if self.phase is Paused {
      self.wake.get()
      continue
    }
    let status = match self.orchestrator.status(task_scope=self.scope) {
      Ok(status) => status
      Err(error) => {
        self.finish(Failed, AdmissionRejected(error))
        return
      }
    }
    self.revision = Some(status.plan.revision)
    if status.owner.unresolved {
      self.finish(Unresolved, UnconfirmedSettlement)
      return
    }
    if !status.admission_enabled {
      let reason = if !status.policy_enabled {
        @orchestration.AdmissionDisabled
      } else if status.owner.active is Some(_) {
        @orchestration.ExecutionActive
      } else if status.owner.closed {
        @orchestration.OwnerClosed
      } else if !status.owner.attached {
        @orchestration.OwnerNotAttached
      } else if status.owner.admission_busy || status.dispatch_busy {
        @orchestration.AdmissionInProgress
      } else {
        @orchestration.HostUnavailable
      }
      self.finish(Failed, OrchestrationBlocked(reason))
      return
    }
    // Missing or denied host input is not permission to silently choose a
    // different task. Structural stage/dependency blocks may still be skipped.
    for row in status.plan.blocked {
      if row.reasons.contains(@orchestration.AuthorizationDenied) {
        self.finish(
          Failed,
          AdmissionRejected(@orchestration.AuthorizationRejected),
        )
        return
      }
      if row.reasons.contains(@orchestration.MissingExecutionInput) {
        self.finish(Failed, AdmissionRejected(@orchestration.InputUnavailable))
        return
      }
    }
    let result = self.orchestrator.dispatch_next(
      planning_revision=status.plan.revision,
      task_scope=self.scope,
      execution_timeout_ms=spec.execution_timeout_ms,
      admission_guard=() => {
        (
          self.active is Some(_) ||
          self.orchestrator.owner_status().active is Some(_) ||
          (self.phase == Running && !self.stop_requested)
        ) &&
        !self.closed &&
        !self.cancel_requested &&
        !self.deadline_expired &&
        self.has_time(spec)
      },
    )
    match result {
      Ok(@orchestration.StalePlan(plan)) => {
        self.revision = Some(plan.revision)
        stale += 1
        if stale >= 8 {
          self.finish(Failed, StalePlanLimit)
          return
        }
        // Only pre-admission stale plans can be recomputed. No command replay.
        continue
      }
      Ok(@orchestration.Blocked(plan)) => {
        self.revision = Some(plan.revision)
        if plan.blocked.any(row => {
            row.reasons.contains(@orchestration.UnresolvedExecution)
          }) {
          self.finish(Unresolved, UnconfirmedSettlement)
        } else {
          self.finish(Completed, NoEligibleWork)
        }
        return
      }
      Err(@orchestration.AdmissionStopped) => continue
      Err(@orchestration.DispatchCancelled(cleanup_confirmed~)) => {
        self.finish(
          if cleanup_confirmed {
            Stopped
          } else {
            Unresolved
          },
          if cleanup_confirmed {
            CancelRequested
          } else {
            UnconfirmedSettlement
          },
        )
        return
      }
      Err(error) => {
        self.finish(Failed, AdmissionRejected(error))
        return
      }
      Ok(@orchestration.Admitted(handle)) => {
        // Store the handle before a cancellation checkpoint can abandon it.
        self.active = Some(handle)
        self.admitted += 1
        stale = 0
        if self.orchestrator.owner_status().active is Some(binding) {
          self.current = Some({
            task_id: binding.task_id,
            attempt_id: binding.attempt_id,
          })
        }
        let binding = handle.wait()
        if !self.record(binding) {
          return
        }
        let state = self.orchestrator.board_state()
        if state is Ok(snapshot) {
          self.revision = Some(snapshot.revision)
        }
        match binding.outcome {
          Some(@execution.Completed) => ()
          Some(@execution.Cancelled) => {
            self.finish(Stopped, ExecutionFailed(@execution.Cancelled))
            return
          }
          Some(outcome) =>
            if spec.failure_policy == StopOnFailure {
              self.finish(Failed, ExecutionFailed(outcome))
              return
            }
          None => {
            self.finish(Unresolved, UnconfirmedSettlement)
            return
          }
        }
      }
    }
  }
}

///|
/// Stops admissions, cancels/joins the loop, then closes S4B/S4A. False MUST
/// retain the host scope and journal lock; repeat after cleanup, never release.
pub async fn SequentialWorkflowRunner::shutdown(
  self : SequentialWorkflowRunner,
  timeout_ms~ : Int32 = 4000,
) -> Bool {
  self.closed = true
  self.cancel()
  if timeout_ms <= 0 {
    return false
  }
  let deadline = (self.now_ms)() + timeout_ms.to_int64()
  let joined = @async.with_timeout(timeout_ms, () => {
    if self.worker is Some(worker) {
      worker.wait()
    }
    true
  }) catch {
    _ => false
  }
  if !joined || self.starting {
    return false
  }
  let remaining = (deadline - (self.now_ms)())
    .max(1L)
    .min(timeout_ms.to_int64())
    .to_int()
  self.orchestrator.shutdown(timeout_ms=remaining)
}
