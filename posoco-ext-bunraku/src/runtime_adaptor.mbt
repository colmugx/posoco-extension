///|
/// Advanced Posoco runtime binding for programmatic tool calls. It is a thin
/// decorator: run_code is an ordinary manifest tool executed through the
/// kernel → host → runtime chain, so the final executor hands the
/// BunrakuExtension provider a kernel-wired `ToolCallContext` whose
/// `tools()`/`invoke()` are the child-pipeline closures. Nested guest calls
/// therefore re-enter the kernel: schema validation, the manifest
/// `tool_call_owners` gate, the composed hook chain (`direct=false`),
/// shared budget/depth, cancellation, and `ToolChildDeclared` attribution.

///|
/// The host hands no providers and owns no name lists. The nested face is a
/// kernel fact computed per operation capture — the guest sees exactly what
/// `ToolCallContext::tools()` allows — and run_code's fixed binding comes
/// from its manifest registration.
pub struct BunrakuRuntime {
  priv fallback : &@runtime.Runtime
  priv presentation : BunrakuExtension
}

///|
pub fn BunrakuRuntime::BunrakuRuntime(
  fallback~ : &@runtime.Runtime,
  presentation? : BunrakuExtension,
  call_observers~ : Array[(NestedCallEvent) -> Unit] = [],
  home? : String,
) -> BunrakuRuntime {
  // run_code is a transport, not a privileged operation. The permission
  // gate must inspect EVERY nested leaf call through the kernel child
  // pipeline, not require a second blanket approval for the enclosing tool.
  publish_tool_exemptions(["run_code"])
  {
    fallback,
    presentation: presentation.unwrap_or_else(() => {
      BunrakuExtension(call_observers~, home?)
    }),
  }
}

///|
/// Announce that `tools` carry their own governance and must bypass an
/// approval gate's checks (legacy topic `"tool_exemptions"`).
///
/// The payload is the closed `@kit_events.ToolExemptions` record, published
/// through an owner-bound capability: the envelope carries
/// `Extension("posoco_ext_bunraku")` instead of a `BusEvent.source` field.
/// Publication happens at construction — the host builds this runtime after
/// the gate has subscribed — and a missing or closed system is a silent
/// no-op, never an error path.
fn publish_tool_exemptions(tools : Array[String]) -> Unit {
  match @devkit.events_system_default() {
    Some(system) =>
      match system.publisher(owner="posoco_ext_bunraku") {
        Ok(publisher) => {
          let payload : @kit_events.ToolExemptionsPayload = { tools, }
          ignore(publisher.publish(@kit_events.ToolExemptions(payload)))
        }
        Err(_) => ()
      }
    None => ()
  }
}

///|
/// Compose this extension, not an ad-hoc BunrakuExtension from the old recipe.
/// When the host supplied its own presentation instance it is the same one
/// declared in the manifest, so declaration and execution share one
/// BunrakuExtension.
pub fn BunrakuRuntime::extension(self : BunrakuRuntime) -> &@posoco.Extension {
  self.presentation as &@posoco.Extension
}

///|
pub impl @runtime.Runtime for BunrakuRuntime with fn call_model(
  self : BunrakuRuntime,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : ((@posoco.StreamChunk) -> Unit)?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  // Additive contract: preserve the complete original model tool surface.
  self.fallback.call_model(
    scope, messages, tool_definitions, call_options, on_chunk,
  )
}

///|
pub impl @runtime.Runtime for BunrakuRuntime with fn execute_tool(
  self : BunrakuRuntime,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  if ctx.tool_name.to_string() == "run_code" &&
    ctx.owner.to_string() == "posoco_ext_bunraku" &&
    ctx.arguments is { "background": true, .. } {
    // A detached background task has no enclosing Effect lifetime or cancel
    // correlation. Reject until the protocol supports an explicit owner
    // scope.
    return @kernel.ToolReportedError(
      content="PTC background execution is unavailable in scoped mode",
      structured=None,
    )
  }
  // Forward the ORIGINAL EffectContext (fixed binding and tool-context
  // factory intact) so the final executor wires the provider context.
  self.fallback.execute_tool(ctx)
}

///|
pub impl @runtime.Runtime for BunrakuRuntime with fn cancel_effects(
  self : BunrakuRuntime,
  run_id~ : @kernel.RunId,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  self.fallback.cancel_effects(run_id~, effect_ids, reason)
}

///|
pub impl @runtime.Runtime for BunrakuRuntime with fn compact(
  self : BunrakuRuntime,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.fallback.compact(scope, messages, tools, call_options, trigger)
}

///|
pub extend BunrakuRuntime with @runtime.Runtime::{
  call_model,
  execute_tool,
  cancel_effects,
  compact,
}
