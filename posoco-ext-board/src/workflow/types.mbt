///|
/// Selection authorizes only these IDs. AllEligibleAtStart freezes the task IDs
/// present at start; neither variant implicitly executes external dependencies.
pub(all) enum WorkflowScope {
  Selected(Array[String])
  AllEligibleAtStart
} derive(Eq, Debug)

///|
pub(all) enum WorkflowFailurePolicy {
  StopOnFailure
  ContinueOnConfirmedFailure
} derive(Eq, Debug)

///|
/// Explicit host authorization, not browser authorization. Execution input is
/// still independently authorized by the S4B resolver for every admission.
pub(all) struct WorkflowRunSpec {
  run_id : String
  scope : WorkflowScope
  max_executions : Int32
  max_elapsed_ms : Int32
  execution_timeout_ms : Int32
  failure_policy : WorkflowFailurePolicy
} derive(Eq, Debug)

///|
/// Budgets and scope are mandatory; only the conservative failure policy has a
/// default. `start` validates the specification before admitting anything.
///
/// ```mbt check
/// test {
///   let spec = @workflow.WorkflowRunSpec(
///     run_id="explicit-host-run",
///     scope=@workflow.AllEligibleAtStart,
///     max_executions=2,
///     max_elapsed_ms=10000,
///     execution_timeout_ms=1000,
///   )
///   assert_true(spec.validate())
///   assert_eq(spec.failure_policy, @workflow.StopOnFailure)
/// }
/// ```
pub fn WorkflowRunSpec::WorkflowRunSpec(
  run_id~ : String,
  scope~ : WorkflowScope,
  max_executions~ : Int32,
  max_elapsed_ms~ : Int32,
  execution_timeout_ms~ : Int32,
  failure_policy~ : WorkflowFailurePolicy = StopOnFailure,
) -> WorkflowRunSpec {
  {
    run_id,
    scope: match scope {
      Selected(ids) => Selected(ids.copy())
      AllEligibleAtStart => AllEligibleAtStart
    },
    max_executions,
    max_elapsed_ms,
    execution_timeout_ms,
    failure_policy,
  }
}

///|
/// Control state only; Pausing lets an admitted run finish, Paused is quiescent.
pub(all) enum WorkflowPhase {
  Idle
  Running
  Pausing
  Paused
  Stopping
  Stopped
  Completed
  Failed
  Unresolved
} derive(Eq, Debug)

///|
pub(all) enum WorkflowStopReason {
  NoEligibleWork
  OrchestrationBlocked(@orchestration.ExecutionBlockReason)
  ExecutionBudgetReached
  InsufficientTime
  DeadlineReached
  StopRequested
  CancelRequested
  HostShutdown
  ExecutionFailed(@execution.BoardExecutionOutcome)
  AdmissionRejected(@orchestration.OrchestrationError)
  UnconfirmedSettlement
  StalePlanLimit
  UnexpectedFailure
} derive(Eq, Debug)

///|
pub(all) enum WorkflowError {
  InvalidSpec
  InvalidScope
  DuplicateRunIdentity
  AlreadyRunning
  Closed
  UnresolvedOwner
  BoardUnavailable
  StartCancelled
} derive(Eq, Debug)

///|
/// Detached metadata only. Board revision is the last authoritative revision
/// observed by this loop, not a promise that the Board has stopped changing.
pub(all) struct WorkflowStatus {
  run_id : String?
  phase : WorkflowPhase
  admitted : Int32
  succeeded : Int32
  failed : Int32
  cancelled : Int32
  remaining_executions : Int32
  started_at_ms : Int64?
  elapsed_ms : Int64
  remaining_ms : Int64
  current : @orchestration.ExecutionCandidate?
  execution_id : String?
  board_revision : Int64?
  reason : WorkflowStopReason?
} derive(Eq, Debug)

///|
/// No unbounded or implicit authorization: at most 1000 runs and 24 hours.
/// Every admission must have room for its configured per-execution timeout.
pub fn WorkflowRunSpec::validate(self : WorkflowRunSpec) -> Bool {
  !self.run_id.trim().is_empty() &&
  self.run_id.length() <= 256 &&
  self.max_executions > 0 &&
  self.max_executions <= 1000 &&
  self.max_elapsed_ms > 0 &&
  self.max_elapsed_ms <= 86400000 &&
  self.execution_timeout_ms > 0 &&
  self.execution_timeout_ms <= self.max_elapsed_ms &&
  (match self.scope {
    AllEligibleAtStart => true
    Selected(ids) =>
      !ids.is_empty() &&
      ids.length() <= 10000 &&
      ids.all(id => !id.trim().is_empty() && id.length() <= 256)
  })
}
