///|
/// Plan mode hook implementations: tool gating + prompt injection.

///|
/// The `cmd` string field used by the bash-family tools.
fn shell_command_of(call : @posoco.ToolCall) -> String? {
  match call.arguments {
    Object(fields) =>
      match fields.get("cmd") {
        Some(String(cmd)) => Some(cmd)
        _ => None
      }
    _ => None
  }
}

///|
/// The `path`/`file_path` string field of write-class tools.
fn write_target_of(call : @posoco.ToolCall) -> String? {
  match call.arguments {
    Object(fields) =>
      match fields.get("path") {
        Some(String(path)) => Some(path)
        _ =>
          match fields.get("file_path") {
            Some(String(path)) => Some(path)
            _ => None
          }
      }
    _ => None
  }
}

///|
fn normalize_target(path : String) -> String {
  let mut current = path
  while current.has_prefix("./") {
    current = current.sub(start=2).to_string()
  }
  current
}

///|
fn target_is_writable(path : String, config : PlanModeConfig) -> Bool {
  let normalized = normalize_target(path)
  let in_paths = config.writable_paths
    .iter()
    .any(fn(prefix) { normalized.has_prefix(prefix) })
  let has_ext = config.writable_extensions
    .iter()
    .any(fn(ext) { normalized.has_suffix(ext) })
  in_paths && has_ext
}

///|
/// The `plan` string field of the exit-tool call; missing/invalid args are
/// the tool execution's validation job.
fn plan_text_of(call : @posoco.ToolCall) -> String? {
  match call.arguments {
    Object(fields) =>
      match fields.get("plan") {
        Some(String(plan)) => Some(plan)
        _ => None
      }
    _ => None
  }
}

///|
/// While Planning/ReadyForApproval: allowed names/patterns pass, shell
/// tools pass read-only commands only, write tools pass only
/// `writable_paths`+`writable_extensions` targets, everything else is
/// rejected with steering. Rejections reach the model as
/// `NotExecuted(RejectedByHook)`; another hook's `ApproveAfterConsent`
/// outranks them.
pub impl @posoco.PipelineHook for PlanMode with fn before_tool(
  self,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  let name = call.name.to_string()
  if self.is_tool_allowed(name) {
    // The review runs HERE because `execute` is a sync slot; the verdict
    // is recorded for it to consume.
    if name == self.config.exit_tool_name && self.status is Planning {
      match self.review {
        Some(source) =>
          match plan_text_of(call) {
            Some(plan) => {
              let decision = source.review(PlanReviewRequest::{ plan, })
              self.review_result = Some((call.call_id.to_string(), decision))
            }
            None => ()
          }
        None => ()
      }
    }
    return @posoco.ToolDecision::Approve(call~)
  }
  if self.config.shell_tools.contains(name) {
    let read_only = match shell_command_of(call) {
      Some(cmd) => @devkit.shell_command_is_read_only(cmd)
      None => false
    }
    if read_only {
      return @posoco.ToolDecision::Approve(call~)
    }
    return @posoco.ToolDecision::Reject(
      reason="plan mode: '\{name}' command is not read-only. Read-only commands (ls, cat, grep, git status, find, …) are allowed while planning; other commands need the user's approval or the plan accepted first. Call '\{self.config.exit_tool_name}' when the plan is ready.",
    )
  }
  if self.config.write_tools.contains(name) {
    match write_target_of(call) {
      Some(path) =>
        if target_is_writable(path, self.config) {
          return @posoco.ToolDecision::Approve(call~)
        }
      None => ()
    }
    return @posoco.ToolDecision::Reject(
      reason="plan mode: while planning, '\{name}' may only touch \{self.config.writable_paths.join(", ")} files ending in \{self.config.writable_extensions.join(", ")}. Put every other change in the plan; it executes after the user accepts it ('\{self.config.exit_tool_name}').",
    )
  }
  @posoco.ToolDecision::Reject(
    reason="plan mode: tool '\{name}' is disabled while planning. Investigate freely, then call '\{self.config.exit_tool_name}' when the plan is ready.",
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
  let shell_line = if config.shell_tools.length() == 0 {
    ""
  } else {
    "Shell tools (\{config.shell_tools.join(", ")}) accept read-only commands with no questions (ls, cat, grep, git status, find); other commands may prompt the user for approval."
  }
  let write_line = if config.write_tools.length() == 0 {
    ""
  } else {
    "You may write Markdown files under \{config.writable_paths.join(", ")} (research notes, draft docs); every other file change goes into the plan itself and executes after the user accepts it."
  }
  let lines = [
    "[PLAN MODE]",
    "You are in plan mode. Investigate freely — arbitrary research is welcome — but do NOT modify anything except Markdown files under \{config.writable_paths.join(", ")}.",
    "Allowed tools while planning: \{allowed}.",
    shell_line,
    write_line,
    "Investigate the request, then write a concrete, step-by-step implementation plan.",
    "When the plan is complete, call '\{exit_tool}' with the full plan to submit it for user approval.",
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
        "[PLAN MODE AVAILABLE]\nFor non-trivial tasks, you may call '\{self.config.enter_tool_name}' to investigate freely (only \{self.config.writable_paths.join(", ")} Markdown is writable) and propose a plan before making changes."
      } else {
        ""
      }
    Planning => build_plan_prompt(self.config)
    ReadyForApproval(..) =>
      "[PLAN MODE]\nA plan has been submitted and is awaiting user approval. Do not make any changes or call '\{self.config.exit_tool_name}' again unless asked to revise the plan."
  }
}
