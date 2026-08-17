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
/// Hook: gate tool execution through an ACP permission request.
///
/// Before asking, queued updates are flushed so the client sees the pending
/// tool-call announcement (and any streamed text) before the decision UI
/// appears. A detached bridge approves everything; a permission transport
/// failure fails closed — the tool never executes without an explicit
/// client allow.
pub impl @posoco.Hook for AcpBridge with fn before_tool(
  self,
  call : @posoco.ToolCall,
) -> @posoco.ToolHookDecision {
  match (self.context, self.session_id) {
    (Some(context), Some(session_id)) => {
      ignore(self.flush())
      if !(self.needs_permission)(call) {
        return @posoco.ToolHookDecision::Approve(call~)
      }
      let response = context.request_permission(
        acp_permission_request(session_id, call),
      ) catch {
        _ =>
          return @posoco.ToolHookDecision::Reject(
            reason="acp: permission request for tool '\{@devkit.sanitize_label(call.name.to_string())}' failed; failing closed",
          )
      }
      acp_decision_from_response(response, call)
    }
    _ => @posoco.ToolHookDecision::Approve(call~)
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
/// Hook (permission gating), Lifecycle (session release). The same `self`
/// reference appears under every field because AcpBridge implements all
/// port traits on the same struct.
pub impl @posoco.Extension for AcpBridge with fn manifest(self) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_acp",
    models: [],
    tools: [],
    sessions: [],
    observers: [self],
    hooks: [self],
    memory: [],
    lifecycle: [self],
    commands: [],
    ui: [],
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
pub fn acp_extension(
  needs_permission? : (@posoco.ToolCall) -> Bool = _ => true,
) -> AcpBridge {
  AcpBridge::new(needs_permission~)
}
