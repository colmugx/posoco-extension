///|
pub using @workflow {
  type WorkflowScope,
  type WorkflowPhase,
  type WorkflowError,
  type WorkflowStopReason,
}

///|
/// Confirmed failures either stop after the wave, continue after its barrier,
/// or cancel the remaining runs. Unresolved always overrides this policy.
pub(all) enum ParallelFailurePolicy {
  StopOnFailure
  ContinueOnConfirmedFailure
  CancelRemainingOnFailure
} derive(Eq, Debug)

///|
/// Trusted-host authorization only. Concurrency defaults to one; all other
/// resource budgets and scope are explicit. Inputs still require the resolver.
pub(all) struct ParallelWorkflowSpec {
  run_id : String
  scope : @workflow.WorkflowScope
  max_concurrency : Int32
  max_executions : Int32
  max_elapsed_ms : Int32
  execution_timeout_ms : Int32
  failure_policy : ParallelFailurePolicy
} derive(Eq, Debug)

///|
/// ```mbt check
/// test {
///   let spec = @parallel.ParallelWorkflowSpec(
///     run_id="host-wave",
///     scope=@workflow.AllEligibleAtStart,
///     max_executions=2,
///     max_elapsed_ms=10000,
///     execution_timeout_ms=1000,
///   )
///   assert_true(spec.validate())
///   assert_eq(spec.max_concurrency, 1)
/// }
/// ```
pub fn ParallelWorkflowSpec::ParallelWorkflowSpec(
  run_id~ : String,
  scope~ : @workflow.WorkflowScope,
  max_executions~ : Int32,
  max_elapsed_ms~ : Int32,
  execution_timeout_ms~ : Int32,
  max_concurrency~ : Int32 = 1,
  failure_policy~ : ParallelFailurePolicy = StopOnFailure,
) -> ParallelWorkflowSpec {
  {
    run_id,
    scope: match scope {
      Selected(ids) => @workflow.Selected(ids.copy())
      AllEligibleAtStart => @workflow.AllEligibleAtStart
    },
    max_concurrency,
    max_executions,
    max_elapsed_ms,
    execution_timeout_ms,
    failure_policy,
  }
}

///|
pub fn ParallelWorkflowSpec::validate(self : ParallelWorkflowSpec) -> Bool {
  self.max_concurrency >= 1 &&
  self.max_concurrency <= 8 &&
  @workflow.WorkflowRunSpec(
    run_id=self.run_id,
    scope=self.scope,
    max_executions=self.max_executions,
    max_elapsed_ms=self.max_elapsed_ms,
    execution_timeout_ms=self.execution_timeout_ms,
  ).validate()
}

///|
/// Detached metadata only. Active rows are actual occupied owner slots, not
/// planned work. Unresolved history blocks admission even after a driver exits.
pub(all) struct ParallelWorkflowStatus {
  run_id : String?
  phase : @workflow.WorkflowPhase
  max_concurrency : Int32
  active : Array[@execution.BoardExecutionBinding]
  active_count : Int32
  available_slots : Int32
  admitted : Int32
  settled : Int32
  succeeded : Int32
  failed : Int32
  cancelled : Int32
  remaining_executions : Int32
  started_at_ms : Int64?
  elapsed_ms : Int64
  remaining_ms : Int64
  board_revision : Int64?
  blocked : Array[@orchestration.BlockedExecution]
  blocked_count : Int32
  blocked_reason_counts : Array[ParallelBlockCount]
  reason : @workflow.WorkflowStopReason?
} derive(Eq, Debug)

///|
pub extend ParallelFailurePolicy with Eq::{equal, not_equal}

///|
pub extend ParallelFailurePolicy with @debug.Debug::{to_repr}

///|
pub extend ParallelWorkflowSpec with Eq::{equal, not_equal}

///|
pub extend ParallelWorkflowSpec with @debug.Debug::{to_repr}

///|
pub extend ParallelWorkflowStatus with Eq::{equal, not_equal}

///|
pub extend ParallelWorkflowStatus with @debug.Debug::{to_repr}

///|
pub(all) struct ParallelBlockCount {
  reason : @orchestration.ExecutionBlockReason
  count : Int32
} derive(Eq, Debug)

///|
pub extend ParallelBlockCount with Eq::{equal, not_equal}

///|
pub extend ParallelBlockCount with @debug.Debug::{to_repr}
