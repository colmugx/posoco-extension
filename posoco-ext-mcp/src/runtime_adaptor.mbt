///|
// Runtime-seam pieces for the Lazy load mode.
//
// A lazily-activated bridge contributes its tools through the catalog seam,
// not through composition-time ToolProvider declarations (the catalog
// snapshot is frozen before the first turn). Two small types close the loop:
//
//   McpCatalogSource — the Agent-wide catalog: static base tools plus the
//     bridge's live defs; `revision()` advances on activation/refresh.
//   McpRuntime — effect execution: MCP-namespaced names route to the
//     bridge, everything else delegates to the fallback runtime.
//
// Wire them together in the host:
//   Agent::with_runtime(exts~, config~,
//     runtime=McpRuntime(bridge~, fallback~),
//     catalog_source=McpCatalogSource(bridge~, base_tools~))

///|
/// Runtime decorator that executes MCP-namespaced tool effects on the
/// bridge and delegates model, non-MCP tool, cancellation, and compaction
/// work to another runtime (typically `@runtime.PortRuntime`).
pub(all) struct McpRuntime {
  bridge : MCPToolBridge
  fallback : &@runtime.Runtime
}

///|
pub fn McpRuntime::McpRuntime(
  bridge~ : MCPToolBridge,
  fallback~ : &@runtime.Runtime,
) -> McpRuntime {
  { bridge, fallback }
}

///|
/// Versioned catalog source combining static Posoco tools with the bridge's
/// live MCP tools.
pub(all) struct McpCatalogSource {
  bridge : MCPToolBridge
  base_tools : Array[@kernel.ToolDef]
}

///|
pub fn McpCatalogSource::McpCatalogSource(
  bridge~ : MCPToolBridge,
  base_tools? : Array[@kernel.ToolDef] = [],
) -> McpCatalogSource {
  { bridge, base_tools }
}

///|
/// Does the bridge currently route this tool name? Execution routing keys
/// on the live map, so the check stays honest across refreshes.
fn McpRuntime::handles(self : McpRuntime, name : String) -> Bool {
  self.bridge.tool_to_conn.contains(name)
}

///|
pub impl @runtime.Runtime for McpRuntime with fn call_model(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : ((@posoco.StreamChunk) -> Unit)?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  self.fallback.call_model(
    scope, messages, tool_definitions, call_options, on_chunk,
  )
}

///|
pub impl @runtime.Runtime for McpRuntime with fn execute_tool(
  self,
  context : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  let name = context.tool_name.to_string()
  if self.handles(name) {
    let call : @kernel.ToolCall = {
      call_id: context.call_id,
      name: context.tool_name,
      arguments: context.arguments,
    }
    @posoco.ToolProvider::execute(self.bridge, name, call) catch {
      error =>
        @kernel.RuntimeFailure(
          error_category="ToolProviderError",
          message=error.to_string(),
        )
    }
  } else {
    self.fallback.execute_tool(context)
  }
}

///|
/// The MCP client exposes no per-effect cancellation, so every effect is
/// delegated: plain tools report `NotPropagated` via the fallback, which is
/// the same contract a ports-only agent has.
pub impl @runtime.Runtime for McpRuntime with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  self.fallback.cancel_effects(effect_ids, reason)
}

///|
pub impl @runtime.Runtime for McpRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.fallback.compact(scope, messages, call_options, trigger)
}

///|
pub impl @runtime.CatalogSource for McpCatalogSource with fn revision(
  self : McpCatalogSource,
) -> Int {
  self.bridge.catalog_revision
}

///|
pub impl @runtime.CatalogSource for McpCatalogSource with fn tools(
  self : McpCatalogSource,
) -> Array[@kernel.ToolDef] {
  let defs : Array[@kernel.ToolDef] = []
  for tool in self.base_tools {
    defs.push(tool)
  }
  for tool in @posoco.ToolProvider::list_tools(self.bridge) {
    defs.push(tool)
  }
  defs
}

///|
pub extend McpRuntime with @runtime.Runtime::{
  call_model,
  execute_tool,
  cancel_effects,
  compact,
}

///|
pub extend McpCatalogSource with @runtime.CatalogSource::{revision, tools}
