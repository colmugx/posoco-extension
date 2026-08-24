///|
/// Port views over the one AcpBridge state.

///|
/// Observer: project every scoped turn event onto queued ACP updates.
/// Synchronous by contract — the queue, not this handler, carries the
/// delivery concern.
pub impl @posoco.Observer for AcpBridge with fn on_event_at(
  self,
  _scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  self.ingest(event)
}

///|
/// ApprovalSource: translate ext-permission's approval asks into ACP
/// `session/request_permission` reverse requests.
///
/// Before asking, queued updates are flushed so the client sees the pending
/// tool-call announcement (and any streamed text) before the decision UI
/// appears. A detached bridge approves every call (`AllowOnce` — nothing
/// is remembered); a permission transport failure fails closed — the tool
/// never executes without an explicit client allow.
///
/// The gating policy — which tools ask, session caching, permission modes —
/// is NOT here: compose `@permission.PermissionPolicy` with this bridge as
/// its approval source. This impl is pure protocol translation.
pub impl @permission.ApprovalSource for AcpBridge with fn ask(
  self : AcpBridge,
  request : @permission.ApprovalRequest,
) -> @permission.ApprovalDecision {
  match (self.context, self.session_id) {
    (Some(context), Some(session_id)) => {
      ignore(self.flush())
      let response = context.request_permission(
        acp_permission_request(session_id, request),
      ) catch {
        _ =>
          return @permission.ApprovalDecision::Deny(
            reason="acp: permission request for tool '\{@devkit.sanitize_label(request.tool_name)}' failed; failing closed",
          )
      }
      acp_decision_from_approval(response, request)
    }
    _ => @permission.ApprovalDecision::AllowOnce
  }
}

///|
/// Lifecycle: release the session on shutdown. The queue is left to the
/// host's `close` (a running pump exits once it closes).
pub impl @posoco.Lifecycle for AcpBridge with fn on_shutdown(self) -> Unit {
  self.detach()
}

///|
/// Self-report AcpBridge's port contributions to the agent composer.
///
/// `id` is the manifest identifier used in composition diagnostics; it is
/// not used for routing or persistence.
pub impl @posoco.Extension for AcpBridge with fn extension_id(_self) -> String {
  "posoco_ext_acp"
}

///|
/// Declare the ports AcpBridge contributes: Observer (event projection),
/// ApprovalSource (ACP permission translation for a composed permission
/// policy), Lifecycle (session release), UiPort (elicitation-based
/// interactive requests). The same `self` reference appears under every
/// field because AcpBridge implements all port traits on the same struct.
pub impl @posoco.Extension for AcpBridge with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_acp",
    models: [],
    tools: [],
    sessions: [],
    observers: [self],
    hooks: [],
    memory: [],
    lifecycle: [self],
    commands: [],
    ui: [self],
    prompt_contributors: [],
    requires: [],
  }
}

///|
/// Expose Extension methods on AcpBridge for dot-syntax callers and so
/// `&AcpBridge` coerces into `Array[&@posoco.Extension]`.
pub extend AcpBridge with @posoco.Extension::{extension_id, manifest}

///|
/// Convenience factory: construct an AcpBridge and return its Extension
/// view. Hosts that already hold an AcpBridge instance should pass it
/// directly instead of calling this helper.
pub fn acp_extension() -> AcpBridge {
  AcpBridge()
}
