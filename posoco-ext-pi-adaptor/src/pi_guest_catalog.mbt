///|
// Read-only catalog projections and catalog-change notification (JS target).
// Keep foreign-runtime implementation here; the public Pi/Posoco mapping lives
// in adaptor, event_observer, hook_adaptor, and runtime_adaptor.

///|
/// Catalog accessors over the host's active tool view (visibleTools): the
/// count and the per-index readers must agree on the same filtered array or
/// list_tools indexes shift. Inactive tools stay registered and executable
/// (visibility-only, like hidden tools).
extern "js" fn js_tool_count(host : JsPiHost) -> Int32 =
  #| (host) => host.visibleTools().length

///|
extern "js" fn js_tool_name(host : JsPiHost, index : Int32) -> String =
  #| (host, index) => host.visibleTools()[index]?.name ?? ""

///|
extern "js" fn js_tool_description(host : JsPiHost, index : Int32) -> String =
  #| (host, index) => host.visibleTools()[index]?.description ?? ""

///|
extern "js" fn js_tool_schema_json(host : JsPiHost, index : Int32) -> String =
  #| (host, index) => JSON.stringify(host.visibleTools()[index]?.parameters ?? { type: "object", properties: {} })

///|
extern "js" fn js_catalog_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.visibleTools().map((tool) => ({
  #|   name: tool.name,
  #|   label: tool.label ?? tool.name,
  #|   description: tool.description,
  #|   parameters: tool.parameters,
  #|   promptSnippet: tool.promptSnippet ?? null,
  #| })))

///|
extern "js" fn js_catalog_snapshot_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify({
  #|   version: host.state.catalogVersion,
  #|   tools: host.visibleTools().map((tool) => ({
  #|     name: tool.name,
  #|     label: tool.label ?? tool.name,
  #|     description: tool.description,
  #|     parameters: tool.parameters,
  #|     promptSnippet: tool.promptSnippet ?? null,
  #|   })),
  #| })

///|
/// Live prompt self-description of the currently registered Pi tools: one
/// JSON entry per tool carrying a non-empty promptSnippet or
/// promptGuidelines, in registration order. Hidden tools (base wins) and
/// tools outside the active set never contribute — the model must not see a
/// snippet for a tool it cannot call. Read fresh on every call so the dynamic
/// catalog is always reflected.
extern "js" fn js_prompt_snippets_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.visibleTools()
  #|   .filter((tool) => !(host.state.hiddenTools?.has(tool.name) ?? false))
  #|   .map((tool) => ({
  #|     name: tool.name,
  #|     snippet: typeof tool.promptSnippet === "string" ? tool.promptSnippet : "",
  #|     guidelines: Array.isArray(tool.promptGuidelines)
  #|       ? tool.promptGuidelines.filter((item) => typeof item === "string")
  #|       : [],
  #|   })).filter((item) => item.snippet.trim().length > 0 || item.guidelines.length > 0))

///|
/// Install the callback fired whenever the JS host's catalog changes:
/// registerTool and setActiveTools both call bumpCatalog(). The MoonBit side
/// only flips a dirty flag; the actual re-publication runs at the next model
/// call.
extern "js" fn js_host_set_on_catalog_change(
  host : JsPiHost,
  callback : () -> Unit,
) -> Unit =
  #| (host, callback) => { host.state.onCatalogChange = callback }

///|
/// Mirror the hidden-tools set into the JS host so host-side live-state
/// readers (the <pi-tools> prompt-block serializer) apply the same base-wins
/// hiding as the MoonBit-side catalog filters. Written only by
/// pi_adaptor_set_hidden_tools_json, which keeps both copies in lockstep.
extern "js" fn js_host_set_hidden_tools(
  host : JsPiHost,
  names_json : String,
) -> Unit =
  #| (host, namesJson) => {
  #|   let names = [];
  #|   try { names = JSON.parse(namesJson) ?? []; } catch {}
  #|   host.state.hiddenTools = new Set(
  #|     Array.isArray(names) ? names.filter((item) => typeof item === "string") : [],
  #|   );
  #| }


 
///|
/// Guest-side active visibility. The Posoco tool-exposure hook uses this only
/// to *narrow* already-composed tools at the next operation boundary.
extern "js" fn js_tool_is_active(host : JsPiHost, name : String) -> Bool =
  #| (host, name) => host.visibleTools().some((tool) => tool.name === name)
