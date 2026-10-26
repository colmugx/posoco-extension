///|
/// Final policy veto for a nested PTC leaf provider. It runs AFTER
/// ScopedDispatch has resolved any rewrites. (Schema validation moved to the
/// kernel pre-pass in posoco 0.23 and is no longer part of nested dispatch.)
/// Unlike the default approval lattice, a guard rejection can never be
/// overridden by a previous ApproveAfterConsent (e.g. plan-mode writes).
pub struct BunrakuGuardedProvider {
  priv inner : &@posoco.ToolProvider
  priv guards : Array[&@posoco.PipelineHook]
}

///|
pub fn BunrakuGuardedProvider::BunrakuGuardedProvider(
  inner~ : &@posoco.ToolProvider,
  guards~ : Array[&@posoco.PipelineHook],
) -> BunrakuGuardedProvider {
  { inner, guards: guards.copy(), }
}

///|
pub impl @posoco.ToolProvider for BunrakuGuardedProvider with fn list_tools(
  self : BunrakuGuardedProvider,
) -> Array[@kernel.ToolDef] {
  self.inner.list_tools()
}

///|
pub impl @posoco.ToolProvider for BunrakuGuardedProvider with fn execute(
  self : BunrakuGuardedProvider,
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
      @posoco.ToolDecision::Approve(call=accepted)
      | @posoco.ToolDecision::ApproveAfterConsent(call=accepted, ..) =>
        if accepted != call {
          return @kernel.ToolReportedError(
            content="PTC final policy attempted to rewrite a validated call",
            structured=None,
          )
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
pub extend BunrakuGuardedProvider with @posoco.ToolProvider::{
  list_tools,
  execute,
}
