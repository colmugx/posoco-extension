///|
/// Final policy veto for a nested PTC leaf provider. It runs AFTER
/// ScopedToolDispatch has resolved any rewrites and validated arguments.
/// Unlike the default approval lattice, a guard rejection can never be
/// overridden by a previous ApproveAfterConsent (e.g. plan-mode writes).
pub struct PtcGuardedProvider {
  priv inner : &@posoco.ToolProvider
  priv guards : Array[&@posoco.PipelineHook]
}

///|
pub fn PtcGuardedProvider::PtcGuardedProvider(
  inner~ : &@posoco.ToolProvider,
  guards~ : Array[&@posoco.PipelineHook],
) -> PtcGuardedProvider {
  { inner, guards: guards.copy(), }
}

///|
pub impl @posoco.ToolProvider for PtcGuardedProvider with fn list_tools(
  self : PtcGuardedProvider,
) -> Array[@kernel.ToolDef] {
  self.inner.list_tools()
}

///|
pub impl @posoco.ToolProvider for PtcGuardedProvider with fn execute(
  self : PtcGuardedProvider,
  ctx : @posoco.ToolCallContext,
) -> @kernel.ToolOutcome raise @posoco.RuntimeError {
  let call : @kernel.ToolCall = {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  }
  for gate in self.guards {
    let decision = gate.before_tool(call) catch {
      error =>
        return @kernel.ToolReportedError(
          content="PTC final policy failed: " + error.to_string(),
          structured=None,
        )
    }
    match decision {
      @posoco.ToolDecision::Approve(call=accepted) |
      @posoco.ToolDecision::ApproveAfterConsent(call=accepted, ..) => {
        if accepted != call {
          return @kernel.ToolReportedError(
            content="PTC final policy attempted to rewrite a validated call",
            structured=None,
          )
        }
      }
      @posoco.ToolDecision::Reject(reason~) =>
        return @kernel.ToolReportedError(
          content="PTC final policy rejected call: " + reason,
          structured=None,
        )
      @posoco.ToolDecision::Defer(reason~) =>
        return @kernel.ToolReportedError(
          content="PTC final policy deferred call: " + reason,
          structured=None,
        )
    }
  }
  self.inner.execute(ctx)
}

///|
pub extend PtcGuardedProvider with @posoco.ToolProvider::{list_tools, execute}
