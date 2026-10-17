///|
/// Opaque, immutable preview. Only this package constructs it. Accessors return
/// detached arrays: neither caller nor approver can mutate the approved plan.
pub struct ExpansionApprovalPreview {
  proposal_id : String
  digest : String
  revision : Int64
  policy : ExpansionPolicySnapshot
  budgets : ExpansionBudgetSnapshot
  authorization_id : String
  workflow : String
  workflow_parent : String
  deadline_ms : Int64
  max_tasks : Int32
  max_edges : Int32
  priv draft_ : DraftExpansion
  priv scope_ : Array[String]
  priv dependencies_ : Array[String]
}

///|
fn copy_draft(draft : DraftExpansion) -> DraftExpansion {
  {
    ..draft,
    tasks: draft.tasks.map(task => {
      ..task,
      definition_of_done: task.definition_of_done.copy(),
      depends_on: task.depends_on.copy(),
    }),
  }
}

///|
pub fn ExpansionApprovalPreview::proposal(
  self : ExpansionApprovalPreview,
) -> DraftExpansion {
  copy_draft(self.draft_)
}

///|
pub fn ExpansionApprovalPreview::workflow_task_scope(
  self : ExpansionApprovalPreview,
) -> Array[String] {
  self.scope_.copy()
}

///|
pub fn ExpansionApprovalPreview::permitted_existing_dependencies(
  self : ExpansionApprovalPreview,
) -> Array[String] {
  self.dependencies_.copy()
}

///|
pub(all) enum ApprovalDecision {
  Grant
  Deny
} derive(Eq, Debug)

///|
pub extend ApprovalDecision with Eq::{equal, not_equal}

///|
pub extend ApprovalDecision with @debug.Debug::{to_repr}

///|
/// Trusted host decision, never a generation-source or browser capability.
pub(open) trait ExpansionApprover {
  fn approve(Self, ExpansionApprovalPreview) -> ApprovalDecision
}

///|
/// Cannot be constructed by a caller, transplanted between hosts or reused.
pub struct ExpansionApproval {
  priv preview_ : ExpansionApprovalPreview
}
