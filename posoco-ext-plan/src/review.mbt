///|
/// Host-injected plan review — the "accept plan" boundary. The UX itself
/// (inline prompt, editor reverse request, external surface) is product
/// content; this port only carries the verdict.
///
/// With a source wired (`PlanMode(review=…)`), the review runs in
/// `before_tool` on the exit-tool call — the async seam, since
/// `ToolProvider::execute` is sync — and the execution consumes the
/// verdict: `Accept` approves and leaves plan mode in one action;
/// `Revise(feedback)` keeps planning with the feedback as the tool result.
/// Without a source the flow stays command-driven (`ReadyForApproval` +
/// `plan.approve` / `plan.reject`).
pub(open) trait PlanReviewSource {
  /// `review` is `async` because rendering the plan to a user may suspend
  /// (editor reverse request, browser surface). A host that decides
  /// synchronously implements it as a plain `fn`.
  async fn review(Self, request : PlanReviewRequest) -> PlanReviewDecision
}

///|
pub(all) struct PlanReviewRequest {
  /// The full submitted plan text.
  plan : String
}

///|
pub impl Show for PlanReviewRequest with fn to_string(self : PlanReviewRequest) -> String {
  "PlanReviewRequest(\{self.plan.length()} chars)"
}

///|
/// The reviewer's verdict.
pub(all) enum PlanReviewDecision {
  Accept
  /// Back to planning; the feedback reaches the model.
  Revise(feedback~ : String)
}

///|
pub impl Show for PlanReviewDecision with fn to_string(
  self : PlanReviewDecision,
) -> String {
  match self {
    Accept => "Accept"
    Revise(feedback~) => "Revise(\{feedback.length()} chars)"
  }
}

///|
/// Always accepts — the unattended (Yolo) posture. Plan rules still apply
/// while planning; only the approval is automatic.
pub(all) struct AutoAcceptReview {}

///|
pub impl PlanReviewSource for AutoAcceptReview with fn review(
  _self : AutoAcceptReview,
  _request : PlanReviewRequest,
) -> PlanReviewDecision {
  Accept
}
