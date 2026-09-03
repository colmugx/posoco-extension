// detect.mbt — pure detection of the lody host: which MCP server names and
// which tool names belong to it. No IO, no ports; the dispatch layer (e.g.
// cetas-acp) calls these before routing tool calls or mounting prompt
// sections.

///|
/// MCP server names under which the lody host injects its tools (the
/// cetas-lody plan: `mcpServers = [lody]`).
pub fn lody_server_names() -> Array[String] {
  ["lody"]
}

///|
/// True when `name` is a lody MCP server name (exact match).
pub fn is_lody_server(name : String) -> Bool {
  lody_server_names().contains(name)
}

///|
/// Wire prefix of the lody MCP tool vocabulary (`lody_session_create`,
/// `lody_session_chat`, `lody_task_*`, ...).
pub const LODY_TOOL_PREFIX : String = "lody_"

///|
/// True when `name` is a lody tool name: a `lody_`-prefixed MCP tool, or one
/// of the canonical `LODY_TOOL_NAMES` identities carried in
/// `_meta.lody.toolName` (canonical identities live in `@lody`; the two
/// surfaces are different namespaces and both count as lody tools).
pub fn is_lody_tool_name(name : String) -> Bool {
  name.has_prefix(LODY_TOOL_PREFIX) || @lody.is_lody_tool_name(name)
}

///|
/// True when the posoco tool call targets a lody tool.
pub fn is_lody_tool_call(call : @posoco.ToolCall) -> Bool {
  is_lody_tool_name(call.name.value)
}
