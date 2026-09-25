///|
/// Memoh-specific approval adapter.
///
/// The wrapped source still performs the real approval round trip (typically
/// ACP session/request_permission handled by Memoh). This wrapper changes only
/// the lifetime semantics: a host response that asks for session/always reuse
/// is deliberately reduced to AllowOnce so Posoco never creates an independent
/// standing grant that can outlive Memoh's own one-shot permission binding.
pub struct MemohApprovalSource {
  delegate : &@permission.ApprovalSource
}

///|
/// Wrap an approval source with Memoh authority semantics.
pub fn MemohApprovalSource::MemohApprovalSource(
  delegate : &@permission.ApprovalSource,
) -> MemohApprovalSource {
  { delegate, }
}

///|
/// Delegate every approval request to Memoh, but never cache a positive grant
/// locally. Denials are preserved exactly.
pub impl @permission.ApprovalSource for MemohApprovalSource with fn ask(
  self : MemohApprovalSource,
  request : @permission.ApprovalRequest,
) -> @permission.ApprovalDecision {
  match self.delegate.ask(request) {
    @permission.ApprovalDecision::AllowOnce |
    @permission.ApprovalDecision::AllowSession |
    @permission.ApprovalDecision::AllowAlways =>
      @permission.ApprovalDecision::AllowOnce
    @permission.ApprovalDecision::Deny(reason~) =>
      @permission.ApprovalDecision::Deny(reason~)
  }
}

///|
pub extend MemohApprovalSource with @permission.ApprovalSource::{ask}
