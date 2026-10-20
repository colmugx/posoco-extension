///|
/// Advanced Posoco runtime binding for programmatic tool calls.
/// The enclosing run_code is a normal reducer-owned Effect. Nested requests
/// deliberately remain private to the MBTX invocation; they are NOT kernel
/// child Effects. Provider capabilities are supplied explicitly by the host.
pub struct PtcRuntime {
  priv fallback : &@runtime.Runtime
  priv tools : Array[&@posoco.ToolProvider]
  priv hooks : Array[&@posoco.PipelineHook]
  priv definitions : Array[@posoco.ToolDef]
  priv presentation : PtcExtension
  priv home : String?
  priv active : Map[Int32, PtcExtension]
}

///|
pub fn PtcRuntime::PtcRuntime(
  fallback~ : &@runtime.Runtime,
  tools~ : Array[&@posoco.ToolProvider],
  hooks~ : Array[&@posoco.PipelineHook] = [],
  final_guards~ : Array[&@posoco.PipelineHook] = [],
  home? : String,
  bus? : @devkit.EventBus,
) -> PtcRuntime raise @posoco.CompositionError {
  let definitions : Array[@posoco.ToolDef] = []
  if tools.is_empty() {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_ptc",
      detail="PTC requires an explicit provider set",
    )
  }
  for provider in tools {
    for definition in provider.list_tools() {
      let name = definition.name.to_string()
      if name == "run_code" || name == "" {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_ptc",
          detail="PTC scope excludes recursive or unnamed tool '" + name + "'",
        )
      }
      definitions.push(definition)
    }
  }
  // Composition gate: reject duplicate tools and unsupported schemas before
  // the Agent starts. Never silently fall back to raw provider dispatch.
  let guarded_providers : Array[&@posoco.ToolProvider] = []
  for provider in tools {
    guarded_providers.push(
      PtcGuardedProvider(inner=provider, guards=final_guards)
      as &@posoco.ToolProvider,
    )
  }
  let _ = @posoco.ScopedToolDispatch(guarded_providers, hooks~)
  // run_code is a transport, not a privileged operation. The permission
  // gate must inspect EVERY nested leaf call, not require a second blanket
  // approval for the enclosing tool. The hard capability gate above
  // prevents unscoped tool execution.
  match bus {
    Some(bus) =>
      bus.publish({
        source: "posoco_ext_ptc",
        topic: "tool_exemptions",
        data: { "tools": ["run_code"] },
      })
    None => ()
  }
  {
    fallback,
    tools: guarded_providers,
    hooks: hooks.copy(),
    definitions,
    presentation: PtcExtension(exposed=definitions, home?),
    home,
    active: Map::from_array([]),
  }
}

///|
/// Compose this extension, not the unscoped PtcExtension from the old recipe.
pub fn PtcRuntime::extension(self : PtcRuntime) -> &@posoco.Extension {
  self.presentation as &@posoco.Extension
}

///|
/// Only run_code is advertised, independently of the fallback's dynamic catalog.
pub struct PtcCatalogSource {
  priv revision_ : Int32
}

///|
pub fn PtcCatalogSource::PtcCatalogSource() -> PtcCatalogSource {
  { revision_: 0, }
}

///|
pub impl @runtime.CatalogSource for PtcCatalogSource with fn revision(
  self : PtcCatalogSource,
) -> Int32 {
  self.revision_
}

///|
pub impl @runtime.CatalogSource for PtcCatalogSource with fn tools(
  _self : PtcCatalogSource,
) -> Array[@posoco.ToolDef] {
  PtcExtension().list_tools()
}

///|
pub extend PtcCatalogSource with @runtime.CatalogSource::{revision, tools}

///|
/// Per-invocation MBTX adapter. It owns a fresh dispatch, never a process-wide
/// invoker or a borrowed raw provider. The dispatch's fixed catalog is the
/// maximum set of operations that any Hook may approve or rewrite to.
pub struct PtcScopedInvoker {
  priv dispatch : @posoco.ScopedToolDispatch
}

///|
pub fn PtcScopedInvoker::PtcScopedInvoker(
  dispatch~ : @posoco.ScopedToolDispatch,
) -> PtcScopedInvoker {
  { dispatch, }
}

///|
pub impl @mbtx.ToolInvoker for PtcScopedInvoker with fn invoke(
  self : PtcScopedInvoker,
  name : String,
  arguments : Json,
) -> @protocol.Outcome {
  match self.dispatch.call(name, arguments) {
    @kernel.Success(content~, structured~) =>
      @protocol.Success(content~, structured~)
    @kernel.SuccessWithAttachments(content~, structured~, ..) =>
      @protocol.Success(content~, structured~)
    @kernel.ToolReportedError(content~, structured~) =>
      @protocol.Failure(code="ToolRejected", content~, structured~)
    @kernel.RuntimeFailure(error_category~, message~) =>
      @protocol.Failure(code=error_category, content=message, structured=None)
    @kernel.NotExecuted(..) =>
      @protocol.Failure(
        code="NotExecuted",
        content="nested tool did not execute",
        structured=None,
      )
  }
}

///|
pub extend PtcScopedInvoker with @mbtx.ToolInvoker::{invoke}

///|
pub impl @runtime.Runtime for PtcRuntime with fn call_model(
  self : PtcRuntime,
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
pub impl @runtime.Runtime for PtcRuntime with fn execute_tool(
  self : PtcRuntime,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  if ctx.tool_name.to_string() != "run_code" ||
    ctx.owner.to_string() != "posoco_ext_ptc" {
    return self.fallback.execute_tool(ctx)
  }
  // A detached background task has no enclosing Effect lifetime or cancel
  // correlation. Reject until the protocol supports an explicit owner scope.
  if ctx.arguments is { "background": true, .. } {
    return @kernel.ToolReportedError(
      content="PTC background execution is unavailable in scoped mode",
      structured=None,
    )
  }
  let dispatch = @posoco.ScopedToolDispatch(self.tools, hooks=self.hooks) catch {
    error =>
      return @kernel.RuntimeFailure(
        error_category="PtcDispatchComposition",
        message=error.to_string(),
      )
  }
  let invoker = PtcScopedInvoker(dispatch~)
  let ptc = PtcExtension(
    exposed=self.definitions,
    scoped_invoker=invoker,
    home?=self.home,
  )
  let id = ctx.effect_id.to_int()
  // Prevent a stale or collided EffectId from silently replacing an active
  // cancellation target. Posoco runs only one active Run per Agent today.
  if self.active.contains(id) {
    return @kernel.RuntimeFailure(
      error_category="PtcEffectCollision",
      message="PTC effect is already active",
    )
  }
  self.active[id] = ptc
  defer self.active.remove(id)
  let tool_ctx : @posoco.ToolCallContext = {
    effect_id: ctx.effect_id,
    call_id: ctx.call_id,
    name: ctx.tool_name,
    arguments: ctx.arguments,
    register_cancel: fn(_ : &@posoco.ToolCancellable) { () },
  }
  ptc.execute(tool_ctx) catch {
    error =>
      @kernel.RuntimeFailure(
        error_category="PtcExecution",
        message=error.to_string(),
      )
  }
}

///|
pub impl @runtime.Runtime for PtcRuntime with fn cancel_effects(
  self : PtcRuntime,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  let results : Array[(@kernel.EffectId, @kernel.CancelDisposition)] = []
  let fallback_ids : Array[@kernel.EffectId] = []
  for id in effect_ids {
    match self.active.get(id.to_int()) {
      Some(ptc) => {
        let disposition = ptc.cancel(id, reason)
        results.push((id, disposition))
      }
      None => fallback_ids.push(id)
    }
  }
  if !fallback_ids.is_empty() {
    for result in self.fallback.cancel_effects(fallback_ids, reason) {
      results.push(result)
    }
  }
  // Return in request order even when the delegated runtime reorders.
  let ordered : Array[(@kernel.EffectId, @kernel.CancelDisposition)] = []
  for id in effect_ids {
    for pair in results {
      let (candidate, disposition) = pair
      if candidate == id {
        ordered.push((id, disposition))
        break
      }
    }
  }
  ordered
}

///|
pub impl @runtime.Runtime for PtcRuntime with fn compact(
  self : PtcRuntime,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.fallback.compact(scope, messages, tools, call_options, trigger)
}

///|
pub extend PtcRuntime with @runtime.Runtime::{
  call_model,
  execute_tool,
  cancel_effects,
  compact,
}
