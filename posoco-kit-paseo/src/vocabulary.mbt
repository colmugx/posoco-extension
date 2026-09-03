// vocabulary.mbt — the Paseo multi-agent orchestration tool vocabulary
// (cetas-paseo-plan Phase 3). Paseo exposes its orchestration tools through
// an MCP fallback with no on-wire prefix, so the names below are the full
// wire identities. Paseo has no official contract repository: the tool list
// comes from the plan's Phase 3 verification set and everything around it is
// a local proposal — awaiting on-wire verification at the cetas-acp dispatch
// point.

///|
/// `create_agent` — spawn a child agent (the parallel delegation entry
/// point).
pub const PASEO_TOOL_CREATE_AGENT : String = "create_agent"

///|
/// `send_agent_prompt` — drive a child agent with one prompt.
pub const PASEO_TOOL_SEND_AGENT_PROMPT : String = "send_agent_prompt"

///|
/// `get_agent_status` — read one child agent's status.
pub const PASEO_TOOL_GET_AGENT_STATUS : String = "get_agent_status"

///|
/// `list_agents` — enumerate the child agents this session owns.
pub const PASEO_TOOL_LIST_AGENTS : String = "list_agents"

///|
/// `cancel_agent` — cooperative stop of a child agent's current work.
pub const PASEO_TOOL_CANCEL_AGENT : String = "cancel_agent"

///|
/// `archive_agent` — retire a finished child agent.
pub const PASEO_TOOL_ARCHIVE_AGENT : String = "archive_agent"

///|
/// `kill_agent` — hard stop of a child agent.
pub const PASEO_TOOL_KILL_AGENT : String = "kill_agent"

///|
/// `update_agent` — reconfigure a live child agent.
pub const PASEO_TOOL_UPDATE_AGENT : String = "update_agent"

///|
/// The Phase 3 tool list, in plan order.
pub fn paseo_tool_names() -> Array[String] {
  [
    PASEO_TOOL_CREATE_AGENT,
    PASEO_TOOL_SEND_AGENT_PROMPT,
    PASEO_TOOL_GET_AGENT_STATUS,
    PASEO_TOOL_LIST_AGENTS,
    PASEO_TOOL_CANCEL_AGENT,
    PASEO_TOOL_ARCHIVE_AGENT,
    PASEO_TOOL_KILL_AGENT,
    PASEO_TOOL_UPDATE_AGENT,
  ]
}

///|
/// MCP server name under which Paseo injects its orchestration tools. The
/// plan pins the injection form (host-side MCP handed over via ACP
/// `session/new.mcpServers`) but never pins the server's name; `paseo` is
/// the local proposal — awaiting on-wire verification.
pub const PASEO_MCP_SERVER_NAME : String = "paseo"

///|
/// True when `name` is one of the canonical Paseo tool names. The vocabulary
/// carries no prefix, so detection is exact table membership only — a
/// `paseo_`-prefixed alias is NOT accepted. Neither surface can be safely
/// prefix-matched: the names are generic verbs that other MCP servers could
/// plausibly reuse, which is why server-name detection is the stronger
/// signal. If a wire prefix shows up, this predicate gains a prefix arm.
pub fn is_paseo_tool_name(name : String) -> Bool {
  paseo_tool_names().contains(name)
}
