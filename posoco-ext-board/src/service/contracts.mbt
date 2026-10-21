///|
/// A composed client supplies capabilities, not a second execution owner.
pub(all) enum WorkflowAgentPurpose {
  Planning
  Execution
} derive(Eq, @debug.Debug)

///|
pub extend WorkflowAgentPurpose with Eq::{equal, not_equal}

///|
pub extend WorkflowAgentPurpose with @debug.Debug::{to_repr}

///|
pub(all) struct WorkflowAgentContext {
  purpose : WorkflowAgentPurpose
  workflow_id : String
  task_id : String
  attempt_id : String
  session_id : String
  slot : Int32
}

///|
/// Fresh extension composition for one Agent. Do not include session/output
/// persistence or workflow mutation tools. Planning must expose no tools.
pub(all) struct WorkflowAgentComposition {
  extensions : Array[&@posoco.Extension]
  config : @posoco.AgentConfig
}

///|
/// Trusted capability composition: allocate fresh mutable model/tool state for
/// each call. Opaque wrappers cannot prove that their backing state is isolated;
/// Board rejects reuse of identical exposed extension/model references as defense
/// in depth, not as a sandbox for an untrusted factory.
pub(open) trait WorkflowAgentFactory {
  async fn prepare(Self, WorkflowAgentContext) -> WorkflowAgentComposition
}

///|
pub struct BoardWorkflowPolicy {
  enabled : Bool
  max_executions : Int32
  max_elapsed_ms : Int32
  execution_timeout_ms : Int32
  max_concurrency : Int32
  max_expansions : Int32
  max_generated_tasks : Int32
  max_depth : Int32
  continue_on_confirmed_failure : Bool
}

///|
pub fn BoardWorkflowPolicy::BoardWorkflowPolicy(
  enabled~ : Bool = false,
  max_executions~ : Int32 = 8,
  max_elapsed_ms~ : Int32 = 600000,
  execution_timeout_ms~ : Int32 = 60000,
  max_concurrency~ : Int32 = 2,
  max_expansions~ : Int32 = 2,
  max_generated_tasks~ : Int32 = 20,
  max_depth~ : Int32 = 16,
  continue_on_confirmed_failure~ : Bool = false,
) -> BoardWorkflowPolicy {
  {
    enabled,
    max_executions,
    max_elapsed_ms,
    execution_timeout_ms,
    max_concurrency,
    max_expansions,
    max_generated_tasks,
    max_depth,
    continue_on_confirmed_failure,
  }
}

///|
fn BoardWorkflowPolicy::spec(
  self : BoardWorkflowPolicy,
  workflow_id : String,
  root : String,
) -> @dynamic.DynamicWorkflowSpec {
  @dynamic.DynamicWorkflowSpec(
    workflow_id~,
    initial_scope=[root],
    max_executions=self.max_executions,
    max_elapsed_ms=self.max_elapsed_ms,
    execution_timeout_ms=self.execution_timeout_ms,
    max_concurrency=self.max_concurrency,
    failure_policy=if self.continue_on_confirmed_failure {
      @parallel.ContinueOnConfirmedFailure
    } else {
      @parallel.StopOnFailure
    },
    expansion=Some(
      @dynamic.DynamicExpansionSpec(
        max_expansions=self.max_expansions,
        max_generated_tasks=self.max_generated_tasks,
        max_depth=self.max_depth,
        scope_approval=@dynamic.HostApprover,
      ),
    ),
  )
}

///|
/// Sanitized product failures. Raw provider/store exceptions are never UI data.
pub(all) enum BoardWorkflowError {
  Disabled
  InvalidConfiguration
  MissingUi
  Closed
  Busy
  NotStarted
  ApprovalDenied
  RevisionConflict
  InvalidProposal
  AgentUnavailable
  StoreUnavailable
  DurabilityUncertain
  UnresolvedExecution
  BudgetExceeded
  NotQuiescent
  PreparationBlocked
  OperationRejected
} derive(Eq, @debug.Debug)

///|
/// Exceptions are an internal short-circuit only. Public product failures remain
/// ordinary Result data, matching the expansion/controller contracts.
priv suberror WorkflowFault {
  WorkflowFault(BoardWorkflowError)
}

///|
pub extend BoardWorkflowError with Eq::{equal, not_equal}

///|
pub extend BoardWorkflowError with @debug.Debug::{to_repr}

///|
pub fn BoardWorkflowError::code(self : BoardWorkflowError) -> String {
  match self {
    Disabled => "workflow_disabled"
    InvalidConfiguration => "invalid_workflow_configuration"
    MissingUi => "trusted_ui_required"
    Closed => "workflow_closed"
    Busy => "workflow_operation_active"
    NotStarted => "workflow_not_started"
    ApprovalDenied => "approval_denied"
    RevisionConflict => "revision_conflict_refresh_required"
    InvalidProposal => "invalid_proposal"
    AgentUnavailable => "planning_agent_unavailable"
    StoreUnavailable => "store_unavailable_inspect_lock_and_storage"
    DurabilityUncertain => "durability_uncertain_inspect_no_retry"
    UnresolvedExecution => "execution_unresolved_lock_retained"
    BudgetExceeded => "workflow_budget_exhausted"
    NotQuiescent => "workflow_not_quiescent"
    PreparationBlocked => "task_preparation_blocked"
    OperationRejected => "workflow_operation_rejected_inspect_status"
  }
}

///|
fn[T] controller_result(
  value : Result[T, @dynamic.DynamicWorkflowError],
) -> T raise WorkflowFault {
  match value {
    Ok(value) => value
    Err(error) =>
      raise WorkflowFault(
        match error {
          @dynamic.Busy => Busy
          @dynamic.Closed => Closed
          @dynamic.BudgetExceeded => BudgetExceeded
          @dynamic.HostPaused | @dynamic.NotQuiescent => NotQuiescent
          @dynamic.StaleRevision
          | @dynamic.ExpansionFailed(@expansion.StalePreview) =>
            RevisionConflict
          @dynamic.ApprovalDenied | @dynamic.ScopeApprovalDenied =>
            ApprovalDenied
          @dynamic.PreparationBlocked => PreparationBlocked
          @dynamic.PreparationUncertain(_) => DurabilityUncertain
          @dynamic.ExpansionFailed(@expansion.DecodeFailed(_)) =>
            InvalidProposal
          @dynamic.ExpansionFailed(@expansion.SourceFailed(_)) =>
            AgentUnavailable
          @dynamic.ExpansionFailed(
            @expansion.Backend(@coordinator.DurabilityUncertain(_))
          ) => DurabilityUncertain
          _ => OperationRejected
        },
      )
  }
}

///|
priv struct GrantGraph {}

///|
impl @expansion.ExpansionApprover for GrantGraph with fn approve(_, _) {
  @expansion.Grant
}

///|
priv struct GrantScope {}

///|
impl @dynamic.ScopeExtensionApprover for GrantScope with fn approve(_, _) {
  @expansion.Grant
}

///|
priv struct WorkflowInputs {
  values : Map[String, (String, @orchestration.AuthorizedExecutionInput)]
}

///|
impl @orchestration.BoardExecutionInputResolver for WorkflowInputs with fn availability(
  self,
  candidate,
) {
  match self.values.get(candidate.attempt_id) {
    Some((task, _)) if task == candidate.task_id => @orchestration.Available
    _ => @orchestration.Denied
  }
}

///|
impl @orchestration.BoardExecutionInputResolver for WorkflowInputs with fn resolve(
  self,
  candidate,
) {
  // Scope is checked in `availability` at planning and is rechecked by the
  // orchestrator's live admission guard before the owner's model gate. Resolve
  // only issues the already-selected candidate's explicit host input.
  match self.values.get(candidate.attempt_id) {
    Some((task, input)) if task == candidate.task_id =>
      @orchestration.Authorized(input)
    _ => @orchestration.NotAuthorized
  }
}
