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
fn target_is_writable(path : String, config : PlanModeConfig) -> Bool {
  config.writable_extensions.iter().any(fn(ext) { path.has_suffix(ext) })
}

///|
/// While Planning/ReadyForApproval: allowed names/patterns pass, shell
/// tools pass read-only commands only, write tools pass only
/// `writable_extensions` targets (workspace confinement is the write
/// tools' own anchoring, not this gate), everything else is rejected with
/// steering. Rejections reach the model as `NotExecuted(RejectedByHook)`;
/// another hook's `ApproveAfterConsent` outranks them. Plan-review of the
/// exit tool is NOT this gate's job — it runs inside the exit tool's
/// execution (see `review.mbt`).
pub impl @posoco.PipelineHook for PlanMode with fn before_tool(
  self,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  let name = call.name.to_string()
  if self.is_tool_allowed(name) {
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
      reason="plan mode: while planning, '\{name}' may only touch files ending in \{self.config.writable_extensions.join(", ")} (research notes, draft plans). Put every other change in the plan; it executes after the user accepts it ('\{self.config.exit_tool_name}').",
    )
  }
  @posoco.ToolDecision::Reject(
    reason="plan mode: tool '\{name}' is disabled while planning. Investigate freely, then call '\{self.config.exit_tool_name}' when the plan is ready.",
  )
}

///|
/// Plan-mode reminder body: the research contract carried on every planning
/// turn. Plan mode IS the research posture — investigate as deeply as
/// needed, and every conclusion the plan rests on must be accurate and
/// traceable.
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
    "You may write files ending in \{config.writable_extensions.join(", ")} anywhere in the workspace (research notes, draft plans); every other file change goes into the plan itself and executes after the user accepts it."
  }
  let lines = [
    "[PLAN MODE]",
    "You are in plan mode — a research posture. Investigate the request as deeply as it takes: read code, run read-only commands, follow references. Do NOT modify anything except \{config.writable_extensions.join(", ")} files in the workspace.",
    "Every conclusion must be accurate and traceable: cite the evidence for each claim (file path and line, command output), verify assumptions before relying on them, and mark anything you could not verify as an explicit assumption.",
    "Allowed tools while planning: \{allowed}.",
    shell_line,
    write_line,
    "Investigate the request, then write a concrete, step-by-step implementation plan.",
    "When the plan is complete, call '\{exit_tool}' with the full plan to submit it for user approval.",
  ]
  lines.join("\n")
}

///|
/// Wrap plan-mode guidance in a `<plan-context>` envelope so it is easy to
/// identify in the transcript and composes with other context envelopes.
fn plan_envelope(kind~ : String, content~ : String) -> String {
  @devkit.context_envelope(ns="plan", kind~, trust=true, content~)
}

///|
/// Prefix used to locate existing plan reminders in the message transcript.
fn plan_context_prefix() -> String {
  "<plan-context"
}

///|
fn is_plan_reminder(msg : @kernel.Message) -> Bool {
  match msg {
    UserMessage(content~) =>
      content
      .iter()
      .any(fn(c) {
        match c {
          Text(text) => text.has_prefix(plan_context_prefix())
          _ => false
        }
      })
    _ => false
  }
}

///|
fn find_plan_reminder(messages : Array[@kernel.Message]) -> Int? {
  for i, msg in messages {
    if is_plan_reminder(msg) {
      return Some(i)
    }
  }
  None
}

///|
fn text_user_message(text : String) -> @kernel.Message {
  UserMessage(content=[Text(text)])
}

///|
/// Idempotent reminder injection: append when absent, replace in place when
/// the text changed (mode switch), and return messages unchanged when the
/// current reminder is already present.
fn inject_or_replace_plan_reminder(
  messages : Array[@kernel.Message],
  text : String,
) -> Array[@kernel.Message] {
  match find_plan_reminder(messages) {
    None => {
      messages.push(text_user_message(text))
      messages
    }
    Some(idx) => {
      let changed = match messages[idx] {
        UserMessage(content~) =>
          match content {
            [Text(existing)] => existing != text
            _ => true
          }
        _ => true
      }
      if changed {
        messages[idx] = text_user_message(text)
      }
      messages
    }
  }
}

///|
/// Per-turn plan-mode reminder injection before the model.
pub impl @posoco.PipelineHook for PlanMode with fn before_model(
  self,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @posoco.HookAbort {
  match self.status {
    Off =>
      if self.prev_status != Off {
        // Transition to Off: append a one-time exit reminder and leave prior
        // plan reminders in the transcript untouched.
        self.prev_status = Off
        messages.push(
          text_user_message(
            plan_envelope(
              kind="exit",
              content="Plan mode has been exited. You may now make changes and use all tools normally.",
            ),
          ),
        )
        messages
      } else {
        messages
      }
    Planning => {
      self.prev_status = Planning
      // Plan-file persistence: capture this round's assistant narrative
      // into the draft, then rewrite the session draft file (no-op without
      // an injected filesystem).
      self.record_draft_delta(messages)
      self.write_draft()
      inject_or_replace_plan_reminder(
        messages,
        plan_envelope(kind="planning", content=build_plan_prompt(self.config)),
      )
    }
    ReadyForApproval(plan~) => {
      self.prev_status = ReadyForApproval(plan~)
      inject_or_replace_plan_reminder(
        messages,
        plan_envelope(
          kind="approval",
          content="A plan has been submitted and is awaiting user approval. Do not make any changes or call '\{self.config.exit_tool_name}' again unless asked to revise the plan.",
        ),
      )
    }
  }
}
