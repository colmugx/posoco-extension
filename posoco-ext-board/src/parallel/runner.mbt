///|
fn ParallelWorkflowRunner::account(
  self : ParallelWorkflowRunner,
  completion : Completion,
) -> Bool {
  if self.accounted.contains(completion.execution_id) {
    return true
  }
  guard completion.binding is Some(binding) &&
    binding.execution_id == completion.execution_id &&
    binding.phase is @execution.Settled &&
    binding.outcome is Some(outcome) else {
    self.wave_unresolved = true
    self.finish(@workflow.Unresolved, @workflow.UnconfirmedSettlement)
    return false
  }
  self.accounted[completion.execution_id] = ()
  self.handles.retain(handle => handle.execution_id() != completion.execution_id)
  self.settled += 1
  match outcome {
    @execution.Completed => self.succeeded += 1
    @execution.Cancelled => self.cancelled += 1
    _ => self.failed += 1
  }
  true
}

///|
fn ParallelWorkflowRunner::admission_open(
  self : ParallelWorkflowRunner,
  spec : ParallelWorkflowSpec,
  candidate : @orchestration.ExecutionCandidate,
) -> Bool {
  let owner = self.orchestrator.owner_status()
  if self.closed ||
    self.cancel_requested ||
    self.deadline_expired ||
    self.wave_unresolved ||
    owner.unresolved ||
    (
      self.wave_failure is Some(_) &&
      spec.failure_policy == CancelRemainingOnFailure
    ) {
    return false
  }
  // A pause/stop/count budget cannot retroactively revoke an admitted run's
  // gate. The deadline and explicit cancellation still withdraw authorization.
  if owner.active_bindings.any(binding => {
      binding.attempt_id == candidate.attempt_id
    }) {
    return true
  }
  self.phase is Running &&
  !self.stop_requested &&
  self.has_time(spec) &&
  self.admitted < spec.max_executions &&
  owner.active_bindings.length() < spec.max_concurrency &&
  (
    self.wave_failure is None ||
    spec.failure_policy == ContinueOnConfirmedFailure
  )
}

///|
fn ParallelWorkflowRunner::watch(
  self : ParallelWorkflowRunner,
  handle : @execution.BoardExecutionHandle,
  spec : ParallelWorkflowSpec,
  group : @async.TaskGroup[Unit],
) -> Unit {
  group.spawn_bg(() => {
    let binding = try handle.wait() catch {
      _ => None
    } noraise {
      value => Some(value)
    }
    if binding is Some(value) &&
      value.phase is @execution.Settled &&
      value.outcome is Some(outcome) {
      if outcome != @execution.Completed {
        if self.wave_failure is None {
          self.wave_failure = Some(outcome)
        }
        if spec.failure_policy == CancelRemainingOnFailure {
          self.cancel_handles()
        }
      }
    } else {
      self.wave_unresolved = true
      self.cancel_handles()
    }
    self.completions.put({ execution_id: handle.execution_id(), binding, })
  })
}

///|
async fn ParallelWorkflowRunner::cleanup(self : ParallelWorkflowRunner) -> Bool {
  self.cancel_handles()
  let joined = @async.with_timeout(4000, () => {
    for handle in self.handles.copy() {
      let binding = try handle.wait() catch {
        _ => None
      } noraise {
        value => Some(value)
      }
      ignore(self.account({ execution_id: handle.execution_id(), binding, }))
    }
    true
  }) catch {
    _ => false
  }
  if !joined ||
    !self.handles.is_empty() ||
    self.orchestrator.owner_status().unresolved {
    self.finish(@workflow.Unresolved, @workflow.UnconfirmedSettlement)
    false
  } else {
    true
  }
}

///|
async fn ParallelWorkflowRunner::drive(
  self : ParallelWorkflowRunner,
  spec : ParallelWorkflowSpec,
) -> Unit {
  self.entered = true
  let remaining = (spec.max_elapsed_ms.to_int64() - self.elapsed_ms())
    .max(1L)
    .to_int()
  let result = @async.handle_cancellation(() => {
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        @async.sleep(remaining)
        self.deadline_expired = true
        raise ParallelDeadline
      })
      self.run_loop(spec, group)
    }) catch {
      ParallelDeadline =>
        if self.phase != @workflow.Unresolved {
          self.finish(@workflow.Stopped, @workflow.DeadlineReached)
        }
      _ =>
        if self.phase != @workflow.Unresolved {
          self.finish(@workflow.Failed, @workflow.UnexpectedFailure)
        }
    }
  })
  @async.protect_from_cancel(() => {
    if result is None && self.phase != @workflow.Unresolved {
      self.finish(
        @workflow.Stopped,
        if self.closed {
          @workflow.HostShutdown
        } else if self.deadline_expired {
          @workflow.DeadlineReached
        } else {
          @workflow.CancelRequested
        },
      )
    }
    if !self.handles.is_empty() {
      ignore(self.cleanup())
    }
    if self.orchestrator.owner_status().unresolved || self.wave_unresolved {
      self.finish(@workflow.Unresolved, @workflow.UnconfirmedSettlement)
    }
  })
}

///|
async fn ParallelWorkflowRunner::run_loop(
  self : ParallelWorkflowRunner,
  spec : ParallelWorkflowSpec,
  group : @async.TaskGroup[Unit],
) -> Unit {
  let mut stale = 0
  while true {
    @async.pause()
    if self.controlled &&
      self.phase is (Failed | Unresolved | Completed | Stopped) {
      return
    }
    if self.cancel_requested || self.closed {
      self.finish(
        @workflow.Stopped,
        if self.closed {
          @workflow.HostShutdown
        } else {
          @workflow.CancelRequested
        },
      )
      return
    }
    if self.stop_requested {
      self.finish(@workflow.Stopped, @workflow.StopRequested)
      return
    }
    if self.controlled && self.phase is (Pausing | Paused) {
      self.phase = @workflow.Paused
      self.wake.get()
      continue
    }
    if self.admitted >= spec.max_executions {
      self.finish(@workflow.Completed, @workflow.ExecutionBudgetReached)
      return
    }
    if !self.has_time(spec) {
      self.finish(@workflow.Completed, @workflow.InsufficientTime)
      return
    }
    if self.phase is Pausing {
      self.phase = @workflow.Paused
    }
    if self.phase is Paused {
      self.wake.get()
      continue
    }
    let status = match self.orchestrator.status(task_scope=self.scope) {
      Ok(status) => status
      Err(error) => {
        self.finish(@workflow.Failed, @workflow.AdmissionRejected(error))
        return
      }
    }
    self.revision = Some(status.plan.revision)
    self.blocked = status.plan.blocked
    if status.owner.unresolved {
      self.finish(@workflow.Unresolved, @workflow.UnconfirmedSettlement)
      return
    }
    if !status.admission_enabled {
      let reason = if !status.policy_enabled {
        @orchestration.AdmissionDisabled
      } else if status.owner.closed {
        @orchestration.OwnerClosed
      } else if !status.owner.attached {
        @orchestration.OwnerNotAttached
      } else if status.owner.admission_busy || status.dispatch_busy {
        @orchestration.AdmissionInProgress
      } else if status.owner.available_slots <= 0 {
        @orchestration.ExecutionActive
      } else {
        @orchestration.HostUnavailable
      }
      self.finish(@workflow.Failed, @workflow.OrchestrationBlocked(reason))
      return
    }
    for row in status.plan.blocked {
      if row.reasons.contains(@orchestration.AuthorizationDenied) {
        self.finish(
          @workflow.Failed,
          @workflow.AdmissionRejected(@orchestration.AuthorizationRejected),
        )
        return
      }
      if row.reasons.contains(@orchestration.MissingExecutionInput) {
        self.finish(
          @workflow.Failed,
          @workflow.AdmissionRejected(@orchestration.InputUnavailable),
        )
        return
      }
    }
    let limit = spec.max_concurrency.min(spec.max_executions - self.admitted)
    let wave = status.plan.eligible[:limit].to_owned()
    if wave.is_empty() {
      if self.controlled {
        self.phase = @workflow.Paused
        continue
      }
      self.finish(@workflow.Completed, @workflow.NoEligibleWork)
      return
    }
    self.wave_failure = None
    self.wave_unresolved = false
    let mut replan = false
    for candidate in wave {
      if !self.admission_open(spec, candidate) {
        break
      }
      // A prior member's durable Start can advance the revision before this
      // member reserves. Re-authorize only this still-eligible pinned candidate;
      // StalePlan guarantees no admission or external effect occurred.
      while self.admission_open(spec, candidate) {
        match
          self.orchestrator.dispatch_next(
            task_scope=[candidate.task_id],
            candidate~,
            execution_timeout_ms=spec.execution_timeout_ms,
            admission_guard=() => self.admission_open(spec, candidate),
            on_admitted=handle => {
              self.handles.push(handle)
              self.admitted += 1
              self.watch(handle, spec, group)
            },
          ) {
          Ok(@orchestration.Admitted(_)) => {
            stale = 0
            break
          }
          Ok(@orchestration.StalePlan(plan)) => {
            stale += 1
            if stale >= 8 {
              self.finish(@workflow.Failed, @workflow.StalePlanLimit)
              return
            }
            if !plan.eligible.contains(candidate) {
              replan = true
              break
            }
            @async.pause()
          }
          Ok(@orchestration.Blocked(_)) => {
            replan = true
            break
          }
          Err(@orchestration.AdmissionStopped) => break
          Err(@orchestration.DispatchCancelled(cleanup_confirmed~)) => {
            self.finish(
              if cleanup_confirmed {
                @workflow.Stopped
              } else {
                @workflow.Unresolved
              },
              if !cleanup_confirmed {
                @workflow.UnconfirmedSettlement
              } else if self.closed {
                @workflow.HostShutdown
              } else if self.deadline_expired {
                @workflow.DeadlineReached
              } else {
                @workflow.CancelRequested
              },
            )
            return
          }
          Err(error) => {
            self.finish(@workflow.Failed, @workflow.AdmissionRejected(error))
            return
          }
        }
      }
      if replan {
        break
      }
    }
    // Every admitted child reports once to the bounded queue. No new wave is
    // planned until ALL these handles confirm Settled, independent of ordering.
    let pending = self.handles.length()
    for _ in 0..<pending {
      if !self.account(self.completions.get()) {
        return
      }
    }
    if self.orchestrator.owner_status().unresolved || self.wave_unresolved {
      self.finish(@workflow.Unresolved, @workflow.UnconfirmedSettlement)
      return
    }
    if self.wave_failure is Some(outcome) &&
      spec.failure_policy != ContinueOnConfirmedFailure {
      self.finish(@workflow.Failed, @workflow.ExecutionFailed(outcome))
      return
    }
    if self.controlled {
      match self.orchestrator.plan(task_scope=self.scope) {
        Ok(plan) => {
          self.revision = Some(plan.revision)
          self.blocked = plan.blocked
        }
        Err(error) => {
          self.finish(@workflow.Failed, @workflow.AdmissionRejected(error))
          return
        }
      }
    } else {
      match self.orchestrator.board_state() {
        Ok(state) => self.revision = Some(state.revision)
        Err(_) => ()
      }
    }
    if self.controlled && !self.cancel_requested && !self.stop_requested {
      self.phase = @workflow.Paused
    }
    if replan {
      stale += 1
      if stale >= 8 {
        self.finish(@workflow.Failed, @workflow.StalePlanLimit)
        return
      }
    }
  }
}

///|
/// Stop admissions, cancel/join the control task and all S4A slots, then close
/// the owner. False requires retaining host scope and native journal lock.
pub async fn ParallelWorkflowRunner::shutdown(
  self : ParallelWorkflowRunner,
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
  if !joined || self.starting || self.planning || self.scope_busy {
    return false
  }
  let remaining = (deadline - (self.now_ms)())
    .max(1L)
    .min(timeout_ms.to_int64())
    .to_int()
  self.orchestrator.shutdown(timeout_ms=remaining)
}
