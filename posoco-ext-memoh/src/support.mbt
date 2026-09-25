///|
/// ACP capabilities a first-class Memoh runtime must advertise.
///
/// These are Agent capabilities returned from initialize, not capabilities of
/// the Memoh client. Product hosts reuse this helper so image prompts,
/// structured embedded context, and the HTTP Tool Gateway cannot drift apart.
pub fn memoh_agent_support() -> @acp.AgentSupport {
  @acp.agent_support(
    prompt_image=true,
    prompt_embedded_context=true,
    mcp_http=true,
  )
}
