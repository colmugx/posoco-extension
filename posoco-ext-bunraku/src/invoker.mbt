///|
/// Trusted integration seam for nested capability calls, executed under host
/// governance. It lives here, not in the MBTX runtime: the runtime is
/// tool-agnostic and only forwards the guest's call frames to an `on_call`
/// handler. This port does not implement governance — see the package README.
pub(open) trait ToolInvoker {
  async fn invoke(Self, name : String, arguments : Json) -> @protocol.Outcome
}
