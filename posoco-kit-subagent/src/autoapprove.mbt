///|
/// Unattended approval source for embedded subagents (design §6.2): the child
/// never surfaces an approval dialog to the parent UI — `ask` always answers
/// `AllowAlways`, so unattended runs cannot hang on a prompt. Kind-level
/// permission modes keep their semantics: a `ReadOnly` kind still hard-rejects
/// writes at the policy level regardless of this source.
pub struct AutoApprove {}

///|
/// Stateless marker value.
pub fn AutoApprove::AutoApprove() -> AutoApprove {
  AutoApprove::{ }
}

///|
/// Always `AllowAlways`, for any request; no state is kept. A sync body is a
/// valid implementation of the async trait slot (colorless coroutines).
pub impl @permission.ApprovalSource for AutoApprove with fn ask(
  _self : AutoApprove,
  _request : @permission.ApprovalRequest,
) -> @permission.ApprovalDecision {
  @permission.ApprovalDecision::AllowAlways
}

///|
pub extend AutoApprove with @permission.ApprovalSource::{ask}
