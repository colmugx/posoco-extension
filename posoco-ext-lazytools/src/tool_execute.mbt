///|
/// The `tool_execute` handler: route to the owning provider with a rebuilt
/// inner call. Outcomes pass through verbatim; raised `RuntimeError`s
/// propagate so the kernel maps them exactly as if the child had been
/// called directly.
async fn LazyTools::execute_deferred(
  self : LazyTools,
  ctx : @posoco.ToolCallContext,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let args = arguments_object("tool_execute", call)
  let tool = required_string("tool_execute", args, "tool")
  let inner_args = optional_object("tool_execute", args, "arguments")
  match self.by_name.get(tool) {
    None =>
      @posoco.ToolOutcome::ToolReportedError(
        content="Unknown deferred tool '\{tool}'. Use tool_list (optionally with a keyword) to discover the folded tools.",
        structured=None,
      )
    Some(pos) => {
      let entry = self.entries[pos]
      let provider = self.providers[entry.provider]
      let inner : @posoco.ToolCall = {
        call_id: call.call_id,
        name: @posoco.ToolName::unchecked(tool),
        arguments: Json::object(inner_args),
      }
      // Same effect identity and registrar ride along, so an interruptible
      // child still registers its cancellable facet for THIS effect.
      let inner_ctx : @posoco.ToolCallContext = {
        effect_id: ctx.effect_id,
        call_id: inner.call_id,
        name: inner.name,
        arguments: inner.arguments,
        register_cancel: ctx.register_cancel,
      }
      provider.execute(inner_ctx)
    }
  }
}
