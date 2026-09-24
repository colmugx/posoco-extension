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
    #|
    #|This host can orchestrate parallel child agents for you.
    #|
    #|- Spawn long independent work as child agents with `create_agent` (one
    #|  call per child — children run in parallel) instead of doing it
    #|  inline; the returned agent id is the only handle for that child, so
    #|  keep it and use it for every later call about it.
    #|
    #|- Drive a child with `send_agent_prompt`; check on it with
    #|  `get_agent_status` and enumerate the fleet with `list_agents`. The
    #|  status fields are the only authority for child state; never infer it
    #|  from a tool's human-readable output.
    #|
    #|- Long-running and scheduled children are normal: the host schedules,
    #|  pauses, persists and resumes them, so poll `get_agent_status` instead
    #|  of waiting synchronously on a finished result.
    #|
    #|- Tear down deliberately: `cancel_agent` stops the current work,
    #|  `kill_agent` is the hard stop, and `archive_agent` retires a finished
    #|  child; `update_agent` reconfigures a live one.
    #|
  )
}
