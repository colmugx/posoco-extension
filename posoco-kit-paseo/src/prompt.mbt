// prompt.mbt — the orchestration prompt section contributed to the system
// prompt when a Paseo host is detected. Pure text; the host decides whether
// and where to mount it (e.g. via a SystemPromptContributor at the
// composition layer). Semantics follow the cetas-paseo-plan: Phase 3 tool
// set, Phase 13 long-running/scheduled children owned by Paseo, Phase 14
// multi-agent fan-out.

///|
/// Prompt section describing Paseo multi-agent orchestration semantics for
/// the agent.
pub fn prompt_section() -> String {
  (
    #|## Delegated agents (paseo)
    #|Use `create_agent` for independent parallel work and reuse the returned
    #|agent id. Drive with `send_agent_prompt`; `get_agent_status`/`list_agents`
    #|are authoritative for state. Long/scheduled children may persist: poll
    #|status instead of waiting synchronously. `cancel_agent` stops work,
    #|`kill_agent` hard-stops, `archive_agent` retires, and `update_agent`
    #|reconfigures.
  )
}
