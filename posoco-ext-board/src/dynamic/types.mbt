///|
/// Why a dynamic workflow operation was refused or failed. Typed payloads
/// only: proposal text, model output and provider diagnostics never appear.
pub(all) enum DynamicWorkflowError {
  InvalidSpec
  InvalidScope
  Closed
  NotStarted
  AlreadyStarted
  BoardUnavailable
  Busy
  HostPaused
  BudgetExceeded
  OperationInterrupted
  PreparationBlocked
  BackendMismatch
  RunnerRejected(@workflow.WorkflowError)
  ExpansionDisabled
  NoActiveProposal
  ProposalActive
  NoUncertainProposal
  ExpansionFailed(@expansion.ExpansionError)
  WorkflowMismatch
  UnknownExpansion
  ParentOutOfScope
  TaskOutOfScope
  InvalidPreparation
  StaleRevision
  NotQuiescent
  DuplicateAuthorization
  ApprovalDenied
  ScopeApprovalDenied
  PreparationFailed(@coordinator.BoardCoordinatorError)
  PreparationUncertain(PreparationRecord)
} derive(Eq, @debug.Debug)

///|
/// The durable stage/queue step a preparation reached. `step` is the step
/// that failed or whose durability is unknown; earlier steps are committed.
pub(all) enum PreparationStep {
  MoveRefining
  MoveReady
  QueueExecute
} derive(Eq, @debug.Debug)

///|
/// Captured identity and step of a partial or uncertain preparation. Records
/// accumulate for the controller lifetime; nothing resets or retries them.
pub(all) struct PreparationRecord {
  task_id : String
  attempt_id : String
  step : PreparationStep
  uncertain : Bool
  base_revision : Int64
  completed_steps : Int32
} derive(Eq, @debug.Debug)

///|
/// Explicit expansion bounds and the scope-approval policy. Expansion is
/// disabled unless the host passes `Some` in `DynamicWorkflowSpec`.
pub(all) struct DynamicExpansionSpec {
  max_expansions : Int32
  max_generated_tasks : Int32
  max_depth : Int32
  scope_approval : DynamicScopeApprovalPolicy
} derive(Eq, @debug.Debug)

///|
pub fn DynamicExpansionSpec::DynamicExpansionSpec(
  max_expansions~ : Int32,
  max_generated_tasks~ : Int32,
  max_depth~ : Int32,
  scope_approval~ : DynamicScopeApprovalPolicy = Denied,
) -> DynamicExpansionSpec {
  { max_expansions, max_generated_tasks, max_depth, scope_approval, }
}

///|
/// Trusted-host approval policy for execution-scope extensions. The default
/// is `Denied`: no approver callback can override a denied policy, and a
/// `HostApprover` policy still requires an explicit per-call `Grant`.
pub(all) enum DynamicScopeApprovalPolicy {
  Denied
  HostApprover
} derive(Eq, @debug.Debug)

///|
/// Explicit S4E2 workflow authorization. The initial task scope is concrete
/// (`Selected`); expansion is disabled unless `expansion` is `Some`.
pub(all) struct DynamicWorkflowSpec {
  workflow_id : String
  initial_scope : Array[String]
  max_executions : Int32
  max_elapsed_ms : Int32
  execution_timeout_ms : Int32
  failure_policy : @parallel.ParallelFailurePolicy
  max_concurrency : Int32
  expansion : DynamicExpansionSpec?
} derive(Eq, @debug.Debug)

///|
pub fn DynamicWorkflowSpec::DynamicWorkflowSpec(
  workflow_id~ : String,
  initial_scope~ : Array[String],
  max_executions~ : Int32,
  max_elapsed_ms~ : Int32,
  execution_timeout_ms~ : Int32,
  max_concurrency~ : Int32 = 1,
  failure_policy~ : @parallel.ParallelFailurePolicy = StopOnFailure,
  expansion~ : DynamicExpansionSpec? = None,
) -> DynamicWorkflowSpec {
  {
    workflow_id,
    initial_scope: initial_scope.copy(),
    max_executions,
    max_elapsed_ms,
    execution_timeout_ms,
    failure_policy,
    max_concurrency,
    expansion,
  }
}

///|
/// Static well-formedness only; budget and scope membership are checked
/// against the live Board at start.
pub fn DynamicWorkflowSpec::validate(self : DynamicWorkflowSpec) -> Bool {
  if !valid_id(self.workflow_id) {
    return false
  }
  if self.max_concurrency < 1 || self.max_concurrency > 8 {
    return false
  }
  if self.initial_scope.is_empty() ||
    self.initial_scope.length() > 200 ||
    self.max_executions < 1 ||
    self.max_executions > 1000 ||
    self.max_elapsed_ms < 1 ||
    self.max_elapsed_ms > 86400000 ||
    self.execution_timeout_ms < 1 ||
    self.execution_timeout_ms > self.max_elapsed_ms {
    return false
  }
  let seen : Set[String] = Set([])
  for id in self.initial_scope {
    if !valid_id(id) || seen.contains(id) {
      return false
    }
    seen.add(id)
  }
  match self.expansion {
    None => true
    Some(expansion) =>
      expansion.max_expansions >= 1 &&
      expansion.max_expansions <= 16 &&
      expansion.max_generated_tasks >= 1 &&
      expansion.max_generated_tasks <= 200 &&
      expansion.max_depth >= 2 &&
      expansion.max_depth <= 16
  }
}

///|
fn valid_id(id : String) -> Bool {
  !id.is_empty() &&
  id.length() <= 128 &&
  !id.iter().any(ch => ch.is_whitespace() || ch.is_control())
}

///|
/// First matching element, or `None`. This core build exposes no
/// `Array::find`; the helper keeps call sites small and total.
fn[T] find_first(items : Array[T], pred : (T) -> Bool) -> T? {
  for item in items {
    if pred(item) {
      return Some(item)
    }
  }
  None
}

///|
/// Detached, immutable preview of one execution-scope extension. The trusted
/// host approver sees exactly this binding: the durable full mapping, the
/// requested canonical IDs and the fresh revision it is bound to.
pub(all) struct ScopeTaskMapping {
  key : String
  task_id : String
} derive(Eq, @debug.Debug)

///|
pub(all) struct ScopeExtensionPreview {
  workflow_id : String
  expansion_id : String
  parent_task_id : String
  mapping : Array[ScopeTaskMapping]
  approved_task_ids : Array[String]
  revision : Int64
  scope_before : Array[String]
  expansions_committed : Int32
  scope_authorizations : Int32
} derive(Eq, @debug.Debug)

///|
/// Trusted host approver for execution-scope extension. Distinct from the
/// S4E1 graph approver: approving a scope never approves a graph and vice
/// versa.
pub(open) trait ScopeExtensionApprover {
  fn approve(Self, ScopeExtensionPreview) -> @expansion.ApprovalDecision
}

///|
/// Read-only detached status. No proposal text, model output, prompt or
/// error text is ever included.
pub(all) struct DynamicWorkflowStatus {
  workflow_id : String
  phase : @workflow.WorkflowPhase
  reason : @workflow.WorkflowStopReason?
  runner : @parallel.ParallelWorkflowStatus
  scope : Array[String]
  scope_authorizations : Int32
  expansions_attempted : Int32
  expansions_committed : Int32
  generated_tasks_committed : Int32
  expansion_enabled : Bool
  expansion_phase : @expansion.ExpansionPhase?
  planning_active : Bool
  partial_preparations : Array[PreparationRecord]
  board_revision : Int64?
  blocked : Array[@orchestration.BlockedExecution]
  pending_proposal_id : String?
  last_committed_expansion_id : String?
  host_paused : Bool
  operation_active : Bool
  unresolved : Bool
  remaining_expansions : Int32
  remaining_generated_tasks : Int32
} derive(Eq, @debug.Debug)

///|
pub extend DynamicWorkflowError with Eq::{equal, not_equal}

///|
pub extend DynamicWorkflowError with @debug.Debug::{to_repr}

///|
pub extend PreparationStep with Eq::{equal, not_equal}

///|
pub extend PreparationStep with @debug.Debug::{to_repr}

///|
pub extend PreparationRecord with Eq::{equal, not_equal}

///|
pub extend PreparationRecord with @debug.Debug::{to_repr}

///|
pub extend DynamicExpansionSpec with Eq::{equal, not_equal}

///|
pub extend DynamicExpansionSpec with @debug.Debug::{to_repr}

///|
pub extend DynamicScopeApprovalPolicy with Eq::{equal, not_equal}

///|
pub extend DynamicScopeApprovalPolicy with @debug.Debug::{to_repr}

///|
pub extend DynamicWorkflowSpec with Eq::{equal, not_equal}

///|
pub extend DynamicWorkflowSpec with @debug.Debug::{to_repr}

///|
pub extend ScopeTaskMapping with Eq::{equal, not_equal}

///|
pub extend ScopeTaskMapping with @debug.Debug::{to_repr}

///|
pub extend ScopeExtensionPreview with Eq::{equal, not_equal}

///|
pub extend ScopeExtensionPreview with @debug.Debug::{to_repr}

///|
pub extend DynamicWorkflowStatus with Eq::{equal, not_equal}

///|
pub extend DynamicWorkflowStatus with @debug.Debug::{to_repr}
