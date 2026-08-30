///|
/// Role a Nowledge Mem thread message carries on the wire. Mirrors the
/// upstream plugin's `"user" | "assistant" | "system"` union. `System` exists
/// for wire completeness but is never produced by `map_messages`: system
/// transcript entries are excluded by design (§10-2).
pub(all) enum NmemRole {
  User
  Assistant
  System
} derive(Debug, Eq)

///|
/// Resolved Nowledge Mem client configuration. Produced by
/// `NmemConfig::resolve`; values are pre-trimmed and blanks have already been
/// treated as missing, so `api_key`/`space`/`agent_id`/`host_agent_id` being
/// `None` means "absent at every source". `api_url` feeds the thread-sync
/// HTTP transport; `mcp_url` is the streamable-HTTP MCP endpoint the lazy
/// tool client connects to (`{api_url}/mcp` by default).
pub(all) struct NmemConfig {
  api_url : String
  mcp_url : String
  api_key : String?
  space : String?
  agent_id : String?
  host_agent_id : String?
  source_app : String
} derive(Debug, Eq)

///|
/// One message of a Nowledge Mem thread sync payload. `metadata` always
/// carries `external_id` (stable for a given source position) and
/// `source_app`. Upstream also carries a timestamp; Posoco transcripts have
/// no timestamp source, so the field is intentionally absent.
pub(all) struct NmemThreadMessage {
  role : NmemRole
  content : String
  metadata : Map[String, Json]
} derive(Debug)
