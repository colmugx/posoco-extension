// detect.mbt — pure detection of the Paseo host: which MCP server names and
// which tool names belong to it. No IO, no ports; the dispatch layer (e.g.
// cetas-acp) calls these before routing tool calls or mounting prompt
// sections.

///|
/// True when any of `names` is the Paseo MCP server name (exact match on the
/// locally proposed `PASEO_MCP_SERVER_NAME`).
pub fn detect_from_server_names(names : Array[String]) -> Bool {
  names.contains(PASEO_MCP_SERVER_NAME)
}

///|
/// True when any of `names` is a canonical Paseo tool name (exact table
/// membership — the vocabulary is unprefixed, so no prefix rule exists).
/// Weaker than server-name detection: an unprefixed generic verb can collide
/// across MCP servers, so prefer `detect_from_server_names` when both
/// signals are available.
pub fn detect_from_tool_names(names : Array[String]) -> Bool {
  names.iter().any(is_paseo_tool_name)
}
