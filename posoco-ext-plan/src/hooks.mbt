///|
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
/// While Planning/ReadyForApproval the gate is a WRITE BLOCK, not an
/// allow-list. Deferred gateway calls are classified by the inner tool
/// name (`LazyTools::unwrap_call`): meta tools pass, the enter/exit pair
/// passes, shell tools pass read-only commands only, write tools pass only
/// `writable_extensions` targets (workspace confinement is the write
/// tools' own anchoring, not this gate), and every other tool passes
/// through — the permission lattice governs it, and a user's just-given
/// consent outranks any reject here. Rejections reach the model as
/// `NotExecuted(RejectedByHook)`. Plan-review of the exit tool is NOT this
/// gate's job — it runs inside the exit tool's execution (see `review.mbt`).
pub impl @posoco.PipelineHook for PlanMode with fn before_tool(
  self,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  if self.status is Off {
    return @posoco.ToolDecision::Approve(call~)
  }
  let (name, effective) = @lazytools.LazyTools::unwrap_call(call)
  // Gateway meta calls have no side effects of their own: `tool_list`
  // only browses the folded catalog, and a well-formed `tool_execute` was
  // already unwrapped above — the literal name survives only for a
  // malformed call, which executes nothing and fails at the gateway.
  if @lazytools.LazyTools::is_meta_tool(name) {
    return @posoco.ToolDecision::Approve(call~)
  }
  if name == self.config.exit_tool_name ||
    (name == self.config.enter_tool_name && self.config.allow_model_entry) {
    return @posoco.ToolDecision::Approve(call~)
  }
  if self.config.shell_tools.contains(name) {
    let read_only = match shell_command_of(effective) {
      Some(cmd) => shell_command_is_read_only(cmd)
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
    match write_target_of(effective) {
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
  // Plan mode only blocks writes: research, search, MCP, and pi tools pass
  // unlisted; the permission gate decides whether they run at all.
  @posoco.ToolDecision::Approve(call~)
}

///|
pub extend PlanMode with @posoco.PipelineHook::{
  on_post_event,
  on_turn_begin,
  on_post_event_at,
  on_turn_end,
}

///|
/// Plan-mode reminder body: the research contract carried on every planning
/// turn. Plan mode IS the research posture — investigate as deeply as
/// needed, and every conclusion the plan rests on must be accurate and
/// traceable.
fn build_plan_prompt(config : PlanModeConfig) -> String {
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
    "Only writes are gated: research, search, and other investigation tools stay usable.",
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
    ReadyForApproval(name~, plan~) => {
      self.prev_status = ReadyForApproval(name~, plan~)
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
