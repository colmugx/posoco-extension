///|
/// Plan mode hook implementations: tool gating + prompt injection.

///|
/// Gate tool execution while plan mode is active.
///
/// While `Planning` or `ReadyForApproval`, any tool outside
/// `config.allowed_tools` (and not the exit tool itself) is rejected. The
/// rejection reason is fed back to the model, steering it toward read-only
/// investigation and the exit tool. `Off` passes everything through.
pub impl @posoco.Hook for PlanMode with fn before_tool(
  self,
  call : @posoco.ToolCall,
) -> @posoco.ToolHookDecision {
  let name = call.name.to_string()
  if self.is_tool_allowed(name) {
    return @posoco.ToolHookDecision::Approve(call~)
  }
  @posoco.ToolHookDecision::Reject(
    reason="plan mode: tool '\{name}' is disabled while planning. Investigate with read-only tools, then call '\{self.config.exit_tool_name}' when the plan is ready.",
  )
}

///|
/// Plan-mode system prompt section. Returned only while planning; the
/// contributor contract skips empty strings, so `Off` injects nothing.
fn build_plan_prompt(config : PlanModeConfig) -> String {
  let allowed = if config.allowed_tools.length() == 0 {
    "none (all tools are disabled)"
  } else {
    config.allowed_tools.join(", ")
  }
  let exit_tool = config.exit_tool_name
  let lines = [
    "[PLAN MODE]",
    "You are in plan mode. Do NOT make any changes to the system.",
    "Allowed tools while planning: \{allowed}.",
    "Investigate the request with read-only tools, then write a concrete, step-by-step implementation plan.",
    "When the plan is complete, call '\{exit_tool}' with the full plan to submit it for user approval.",
    "Do not attempt write, edit, or shell tools — they will be rejected until the user approves the plan.",
  ]
  lines.join("\n")
}

///|
/// Inject plan-mode guidance into the aggregate system prompt.
pub impl @posoco.SystemPromptContributor for PlanMode with fn system_prompt(
  self,
) -> String {
  match self.status {
    Off =>
      if self.config.allow_model_entry {
        "[PLAN MODE AVAILABLE]\nFor non-trivial tasks that modify the system, you may call '\{self.config.enter_tool_name}' to investigate read-only and propose a plan before making changes."
      } else {
        ""
      }
    Planning => build_plan_prompt(self.config)
    ReadyForApproval(..) =>
      "[PLAN MODE]\nA plan has been submitted and is awaiting user approval. Do not make any changes or call '\{self.config.exit_tool_name}' again unless asked to revise the plan."
  }
}
