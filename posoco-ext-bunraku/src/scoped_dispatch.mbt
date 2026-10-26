///|
/// Fixed-binding nested dispatcher for PTC guests. This replaces the
/// `ScopedToolDispatch` seam removed in posoco 0.23: routes are bound at
/// composition time from the explicit provider set, nested calls never
/// re-enter `run_code`, and hook decisions run locally before routing.
pub struct ScopedDispatch {
  priv routes : Map[String, &@posoco.ToolProvider]
  priv hooks : Array[&@posoco.PipelineHook]
  priv mut next_call : Int32
}

///|
/// Build the nested dispatch table. Duplicate tool names fail composition
/// exactly like the removed posoco-side dispatcher did.
fn ScopedDispatch::new(
  tools~ : Array[&@posoco.ToolProvider],
  hooks~ : Array[&@posoco.PipelineHook] = [],
) -> ScopedDispatch raise @posoco.CompositionError {
  let routes : Map[String, &@posoco.ToolProvider] = Map([])
  for provider in tools {
    for definition in provider.list_tools() {
      let name = definition.name.to_string()
      if name == "run_code" || name == "" {
        // The PTC constructor already rejects recursive or unnamed tools;
        // stay defensive against providers that add them later.
        continue
      }
      if routes.contains(name) {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_bunraku",
          detail="duplicate nested tool '" + name + "'",
        )
      }
      routes[name] = provider
    }
  }
  { routes, hooks: hooks.copy(), next_call: 0, }
}

///|
/// A nested program call cannot be recursively dispatched to run_code,
/// regardless of whether a host accidentally included it in the catalog.
async fn ScopedDispatch::call(
  self : ScopedDispatch,
  name : String,
  arguments : Json,
) -> @kernel.ToolOutcome {
  if name == "run_code" {
    return @kernel.ToolReportedError(
      content="recursive program calls are not admitted",
      structured=None,
    )
  }
  self.next_call += 1
  let call_id = @posoco.CallId::unchecked(
    "scoped-" + self.next_call.to_string(),
  )
  let mut call : @posoco.ToolCall = {
    call_id,
    name: @posoco.ToolName::unchecked(name),
    arguments,
  }
  let mut rejection : String? = None
  let mut consented : @posoco.ToolCall? = None
  for hook in self.hooks {
    let decision = hook.before_tool(call) catch {
      error =>
        return @kernel.ToolReportedError(
          content="scoped hook failed: " + error.to_string(),
          structured=None,
        )
    }
    match decision {
      @posoco.ToolDecision::Approve(call=rewritten) => {
        if rewritten.call_id != call_id {
          return @kernel.ToolReportedError(
            content="nested hook attempted to change call identity",
            structured=None,
          )
        }
        call = rewritten
      }
      @posoco.ToolDecision::ApproveAfterConsent(call=approved, consent_scope=_) => {
        if approved.call_id != call_id {
          return @kernel.ToolReportedError(
            content="nested hook attempted to change call identity",
            structured=None,
          )
        }
        call = approved
        consented = Some(approved)
      }
      @posoco.ToolDecision::Reject(reason~) => rejection = Some(reason)
      @posoco.ToolDecision::Defer(reason~) =>
        return @kernel.ToolReportedError(
          content="nested tool deferred: " + reason,
          structured=None,
        )
    }
  }
  if consented is Some(granted) && granted != call {
    return @kernel.ToolReportedError(
      content="nested tool changed after approval",
      structured=None,
    )
  }
  if rejection is Some(reason) && consented is None {
    return @kernel.ToolReportedError(content=reason, structured=None)
  }
  let selected = call.name.to_string()
  let provider = match self.routes.get(selected) {
    Some(provider) => provider
    None =>
      return @kernel.ToolReportedError(
        content="nested tool capability unavailable: " + selected,
        structured=None,
      )
  }
  // This provisional dispatch is owned by the enclosing program; its
  // cancellation must unwind the child as part of the program's task group.
  // The reducer never allocates a separate EffectId for this operation.
  let call_ctx : @posoco.ToolCallContext = @posoco.ToolCallContext(
    effect_id=@kernel.EffectId::first(),
    call_id=call.call_id,
    name=call.name,
    arguments=call.arguments,
    register_cancel=fn(_ : &@posoco.ToolCancellable) { () },
  )
  provider.execute(call_ctx) catch {
    error =>
      @kernel.RuntimeFailure(
        error_category="ScopedToolProviderError",
        message=error.to_string(),
      )
  }
}
