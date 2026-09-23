///|
/// Host-injected plan review — the "accept plan" boundary. The UX itself
/// (inline prompt, editor reverse request, external surface) is product
/// content; this port only carries the verdict.
///
/// With a source wired (`PlanMode(review=…)`), the review runs inside the
/// `exit_plan_mode` execution: `Accept` approves and leaves plan mode in
/// one action; `Revise(feedback)` keeps planning with the feedback as the
/// tool result. Without a source the flow stays command-driven
/// (`ReadyForApproval` + `plan.approve` / `plan.reject`).
pub(open) trait PlanReviewSource {
  /// `review` is `async` because rendering the plan to a user may suspend
  /// (editor reverse request, browser surface). A host that decides
  /// synchronously implements it as a plain `fn`.
  async fn review(Self, request : PlanReviewRequest) -> PlanReviewDecision
}

///|
pub(all) struct PlanReviewRequest {
  /// Model-chosen plan name (validated non-empty; also the saved file name
  /// stem). Host UIs should surface it — it identifies the plan better than
  /// a content preview.
  name : String
  /// The full submitted plan text. Never truncated by core; previewing,
  /// collapsing, and markdown rendering are host-UI concerns.
  plan : String
}

///|
pub impl Show for PlanReviewRequest with fn to_string(self : PlanReviewRequest) -> String {
  "PlanReviewRequest(name=\{self.name}, \{self.plan.length()} chars)"
}

///|
pub extend PlanReviewRequest with Show::{to_string, output}

///|
pub(all) enum PlanReviewDecision {
  Accept
  /// Back to planning; the feedback reaches the model. Rejection always
  /// carries a reason — the type has no reasonless Revise.
  Revise(feedback~ : String)
  /// Cancel the plan and stop the turn. Posoco has no tool-level turn
  /// kill switch, so the stop is best-effort: plan mode goes `Off` and
  /// the tool result instructs the model to make no further tool calls.
  Dismiss
}

///|
pub impl Show for PlanReviewDecision with fn to_string(
  self : PlanReviewDecision,
) -> String {
  match self {
    Accept => "Accept"
    Revise(feedback~) => "Revise(\{feedback.length()} chars)"
    Dismiss => "Dismiss"
  }
}

///|
pub extend PlanReviewDecision with Show::{to_string, output}

///|
/// Product rule: an implementation of this trait speaks for the user, so
/// nothing here may auto-derive a verdict — also in an unattended (Yolo)
/// permission posture. Without a source, `exit_plan_mode` records
/// `ReadyForApproval` and only an explicit `plan.approve` implements.
