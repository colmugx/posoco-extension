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
fn path_under_writable_root(path : String, config : PlanModeConfig) -> Bool {
  config.writable_roots
  .iter()
  .any(fn(root) { @workspace.is_lexically_inside(path, root) })
}

///|
/// Lexical workspace containment, mirrored from the permission gate's
/// `path_inside_workspace`: absolute targets under a relative root cannot
/// be proven inside and refuse.
fn path_inside_workspace(
  anchor : @devkit.WorkspaceAnchor,
  path : String,
) -> Bool {
  let root = anchor.root
  if path.has_prefix("/") && !root.has_prefix("/") {
    return false
  }
  let resolved = anchor.resolve(path)
  if root == "." {
    !(resolved == ".." || resolved.has_prefix("../"))
  } else {
    resolved == root || resolved.has_prefix(root + "/")
  }
}

///|
/// The one write-target rule shared by the write-tool gate and the shell
/// gate's redirect/carve-out analysis: a path is writable when it is
/// lexically confined to a `writable_roots` directory (/tmp), or — with
/// an anchor wired — inside the workspace with a `writable_extensions`
/// suffix. The path is normalized first, so `..` escapes classify by
/// where they land; symlink escapes stay the tools' and permission
/// layer's concern.
fn target_is_writable(
  path : String,
  config : PlanModeConfig,
  anchor : @devkit.WorkspaceAnchor?,
) -> Bool {
  let path = @workspace.normalize_lexical(path)
  if path_under_writable_root(path, config) {
    return true
  }
  match anchor {
    Some(anchor) =>
      path_inside_workspace(anchor, path) &&
      config.writable_extensions.iter().any(fn(ext) { path.has_suffix(ext) })
    None => false
  }
}

///|
/// While Planning/ReadyForApproval the gate is a WRITE BLOCK, not an
/// allow-list. Deferred gateway calls are classified by the inner tool
/// name (`LazyTools::unwrap_call`): meta tools pass, the enter/exit pair
/// passes, shell tools pass everything that cannot write outside the
/// writable areas (shell_gate.mbt), write tools pass only writable
/// targets (`target_is_writable`), and every other tool passes
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
    let allowed = match shell_command_of(effective) {
      Some(cmd) => {
        let writable = fn(path : String) {
          target_is_writable(path, self.config, self.anchor)
        }
        shell_command_is_allowed(cmd, writable~)
      }
      None => false
    }
    if allowed {
      return @posoco.ToolDecision::Approve(call~)
    }
    return @posoco.ToolDecision::Reject(
      reason="plan mode: '\{name}' would write outside the writable areas (workspace .md files, /tmp). While planning, investigation commands run freely — keep redirections and file mutations inside /tmp or /dev/null. Call '\{self.config.exit_tool_name}' when the plan is ready.",
    )
  }
  if self.config.write_tools.contains(name) {
    match write_target_of(effective) {
      Some(path) =>
        if target_is_writable(path, self.config, self.anchor) {
          return @posoco.ToolDecision::Approve(call~)
        }
      None => ()
    }
    return @posoco.ToolDecision::Reject(
      reason="plan mode: while planning, '\{name}' may only write .md files in the workspace and paths under /tmp (scratch output). Put every other change in the plan; it executes after the user accepts it ('\{self.config.exit_tool_name}').",
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
    "Shell tools (\{config.shell_tools.join(", ")}) run every non-writing command freely; writes are confined to /tmp and /dev/null (redirects into /tmp are fine) plus .md files in the workspace — anything else that could write elsewhere is blocked."
  }
  let write_line = if config.write_tools.length() == 0 {
    ""
  } else {
    "You may write .md files anywhere in the workspace (research notes, draft plans) and scratch files under /tmp; every other file change goes into the plan itself and executes after the user accepts it."
  }
  let lines = [
    "[PLAN MODE]",
    "You are in plan mode — a research posture. Investigate the request as deeply as it takes: read code, run shell commands that do not write outside /tmp and workspace .md files, follow references. Do NOT modify anything else.",
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
fn find_plan_reminder(messages : Array[@kernel.Message]) -> Int32? {
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

///|
/// MoonBit no longer implicitly promotes the sync trait methods of a
/// `pub impl` as regular methods (warning implicit_impl_as_method). This
/// trait-default method has no direct callers — the kernel consumes it via
/// the trait — so declare the required explicit promotion and mark it
/// deprecated to keep it out of the advertised API.
#deprecated
pub extend PlanMode with @posoco.PipelineHook::{tool_exposure}
