///|
/// Complete workflow composition; low-level S4 packages remain optional
/// advanced ports, not prerequisites customers must assemble themselves.
pub using @service {
  type BoardWorkflows,
  type BoardWorkflowPolicy,
  type BoardWorkflowView,
  type BoardWorkflowError,
  type WorkflowAgentPurpose,
  type WorkflowAgentContext,
  type WorkflowAgentComposition,
  trait WorkflowAgentFactory,
}
