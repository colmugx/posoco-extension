///|
/// Policy defaults to disabled. Dependency Done is a Board-stage convention,
/// not evidence that an Agent succeeded. Only trusted hosts opt in.
pub struct ExecutionPolicy {
  id : String
  enabled : Bool
  priv stages_ : Array[@domain.BoardStage]
}

///|
/// Detached stage allowlist; no domain FSM changes.
///
/// ```mbt check
/// test {
///   let policy = @orchestration.ExecutionPolicy()
///   assert_false(policy.enabled)
///   assert_eq(policy.stages(), [@domain.Ready])
/// }
/// ```
pub fn ExecutionPolicy::ExecutionPolicy(
  enabled? : Bool = false,
  stages? : Array[@domain.BoardStage] = [@domain.Ready],
  id? : String = "ready-dependencies-done-v1",
) -> ExecutionPolicy {
  { id, enabled, stages_: stages.copy(), }
}

///|
pub fn ExecutionPolicy::stages(
  self : ExecutionPolicy,
) -> Array[@domain.BoardStage] {
  self.stages_.copy()
}

///|
/// A metadata hint only. Resolve must independently authorize explicit intent.
pub(all) enum ExecutionInputStatus {
  Available
  Missing
  Denied
} derive(Eq, Debug)

///|
pub(all) struct ExecutionInputAvailability {
  task_id : String
  attempt_id : String
  status : ExecutionInputStatus
} derive(Eq, Debug)

///|
pub(all) enum ExecutionBlockReason {
  AdmissionDisabled
  TaskStageIneligible
  MissingDependency(String)
  DependencyNotDone(String)
  NoQueuedExecuteAttempt
  MissingExecutionInput
  AuthorizationDenied
  IdentityAlreadyUsed
  ExecutionActive
  AdmissionInProgress
  UnresolvedExecution
  HostUnavailable
  OwnerNotAttached
  OwnerClosed
} derive(Eq, Debug)

///|
/// IDs only. A candidate is not a durable reservation or reusable execution.
pub(all) struct ExecutionCandidate {
  task_id : String
  attempt_id : String
} derive(Eq, Debug)

///|
/// One blocked row per task, with deterministic reasons and preferred Attempt.
pub(all) struct BlockedExecution {
  task_id : String
  attempt_id : String?
  reasons : Array[ExecutionBlockReason]
} derive(Eq, Debug)

///|
/// Detached ephemeral output; contains neither prompts nor authoritative entities.
pub(all) struct ExecutionPlan {
  revision : Int64
  policy_id : String
  eligible : Array[ExecutionCandidate]
  blocked : Array[BlockedExecution]
} derive(Eq, Debug)

///|
/// Ephemeral host authorization plus fresh, dedicated identities. This payload
/// is never retained by the planner, status or orchestration journal (none exists).
pub(all) struct AuthorizedExecutionInput {
  execution_id : String
  session_id : String
  input : String
  timeout_ms : Int?
}

///|
pub(all) enum ExecutionInputResolution {
  Authorized(AuthorizedExecutionInput)
  InputMissing
  NotAuthorized
}

///|
/// Trusted host boundary. Availability must be synchronous metadata inspection,
/// not an Agent call, reservation or credential/prompt disclosure. Resolve
/// re-authorizes and allocates fresh session/execution IDs; it must be cancellable
/// and must never start external work. No default input from task descriptions.
pub(open) trait BoardExecutionInputResolver {
  fn availability(Self, ExecutionCandidate) -> ExecutionInputStatus
  async fn resolve(Self, ExecutionCandidate) -> ExecutionInputResolution
}

///|
pub(all) enum OrchestrationError {
  BoardUnavailable
  Closed
  Busy
  ResolutionFailed
  InputUnavailable
  AuthorizationRejected
  OwnerRejected(@execution.BoardExecutionError)
  DispatchCancelled(cleanup_confirmed~ : Bool)
} derive(Eq, Debug)

///|
pub(all) enum ExecutionDispatch {
  Admitted(@execution.BoardExecutionHandle)
  Blocked(ExecutionPlan)
  StalePlan(ExecutionPlan)
}

///|
/// Policy opt-in and effective owner admission are separate. Neither flag
/// promises a candidate exists or reserves capacity; inspect the current plan.
pub(all) struct OrchestrationStatus {
  policy_enabled : Bool
  admission_enabled : Bool
  dispatch_busy : Bool
  owner : @execution.BoardExecutionOwnerStatus
  plan : ExecutionPlan
}
