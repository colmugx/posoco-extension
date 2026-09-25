///|
fn memoh_nullable_bool(value : @acp.ProtocolNullable[Bool]) -> Bool {
  match value {
    @acp.ProtocolNullable::Value(value) => value
    @acp.ProtocolNullable::Null | @acp.ProtocolNullable::Omitted => false
  }
}

///|
/// Validate the capability contract required by the dedicated Memoh runtime.
///
/// cetas-memoh is not a generic ACP fallback. It requires structured host
/// context, direct image prompt support, and HTTP MCP so Memoh can inject its
/// Tool Gateway. A client that cannot provide these capabilities is rejected
/// during startup instead of silently downgrading semantics.
pub fn require_memoh_agent_capabilities(
  capabilities : @acp.ProtocolNullable[@acp.AgentCapabilities],
) -> Unit raise MemohError {
  let caps = match capabilities {
    @acp.ProtocolNullable::Value(value) => value
    @acp.ProtocolNullable::Null | @acp.ProtocolNullable::Omitted =>
      raise MissingAgentCapability(capability="agent_capabilities")
  }

  let prompt = match caps.prompt_capabilities {
    @acp.ProtocolNullable::Value(value) => value
    @acp.ProtocolNullable::Null | @acp.ProtocolNullable::Omitted =>
      raise MissingAgentCapability(capability="prompt_capabilities")
  }

  if !memoh_nullable_bool(prompt.embedded_context) {
    raise MissingAgentCapability(capability="prompt.embedded_context")
  }
  if !memoh_nullable_bool(prompt.image) {
    raise MissingAgentCapability(capability="prompt.image")
  }

  let mcp = match caps.mcp_capabilities {
    @acp.ProtocolNullable::Value(value) => value
    @acp.ProtocolNullable::Null | @acp.ProtocolNullable::Omitted =>
      raise MissingAgentCapability(capability="mcp_capabilities")
  }
  if !memoh_nullable_bool(mcp.http) {
    raise MissingAgentCapability(capability="mcp.http")
  }
}
