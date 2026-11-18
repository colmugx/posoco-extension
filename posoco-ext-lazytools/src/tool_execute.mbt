///|
/// The `tool_execute` handler: re-enter the kernel child pipeline for one
/// deferred tool. The child keeps its own identity — schema validation, the
/// owner gate from `tool_call_owners`, the composed hook chain (permission,
/// plan, rewriting), budget/depth accounting, cancellation and
/// `ToolChildDeclared` attribution — so this gateway adds discovery, not a
/// second execution path.

///|
/// Is `name` in this operation's deferred face? The kernel face is derived
/// from the same `tool_call_owners` declaration, so an absent name is either
/// unknown or owned by someone this gateway may not reach; both are answered
/// here with steering instead of a bare rejection reason.
fn LazyTools::in_live_face(
  _self : LazyTools,
  ctx : @posoco.ToolCallContext,
  name : String,
) -> Bool {
  let mut known = false
  for def in ctx.tools() {
    if def.name.to_string() == name {
      known = true
      break
    }
  }
  known
}

///|
async fn LazyTools::execute_deferred(
  self : LazyTools,
  ctx : @posoco.ToolCallContext,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let args = arguments_object("tool_execute", call)
  let tool = required_string("tool_execute", args, "tool")
  let inner_args = optional_object("tool_execute", args, "arguments")
  if !self.in_live_face(ctx, tool) {
    return @posoco.ToolOutcome::ToolReportedError(
      content="Unknown deferred tool '\{tool}'. Use tool_list (optionally with a keyword) to discover the tools reachable in this operation.",
      structured=None,
    )
  }
  let result = ctx.invoke(tool, Json::object(inner_args))
  match result {
    @posoco.InvocationResult::Completed(outcome) => outcome
    // An ended invocation scope is not a child failure; the reason and
    // cancellation state travel to the model verbatim instead of being
    // reported as a clean miss.
    @posoco.InvocationResult::Interrupted(
      reason~,
      cancellation~,
      side_effects_possible~,
    ) =>
      @posoco.ToolOutcome::ToolReportedError(
        content="Deferred tool '\{tool}' did not run: \{reason} (cancellation=\{cancellation.to_string()}, side_effects_possible=\{side_effects_possible.to_string()})",
        structured=None,
      )
  }
}
