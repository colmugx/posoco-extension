///|
/// Default permission posture for coding-agent tools. `Yolo` pre-approves
/// everything — the approval source is never consulted.
pub(all) enum PermissionMode {
  ReadOnly
  WorkspaceWrite
  Interactive
  Yolo
} derive(Eq, Debug)

///|
/// What the policy wants the host to approve. The host renders this however
/// it likes (modal, inline prompt, protocol reverse-request) and returns a
/// decision.
pub(all) struct ApprovalRequest {
  /// Tool name as it appears in the ToolCall.
  tool_name : String
  /// Stable call id, for correlation in the UI.
  call_id : String
  /// Policy classification: "read" | "write" | "shell" | "unknown".
  category : String
  /// Truncated argument preview, for the user to see what will run. The
  /// policy truncates to a bounded length so secrets/large payloads do not
  /// flood the prompt.
  arguments_preview : String
  /// Full parsed arguments of the call. Rich decision UIs and protocol
  /// bridges (e.g. ACP's `session/request_permission` `raw_input`) need the
  /// complete payload, not the preview.
  arguments : Json
}

///|
/// The host's verdict.
///
/// Allow decisions surface to the agent as `ApproveAfterConsent` — explicit
/// user consent — so in the pump's hook lattice they outrank another gate's
/// `Reject` (plan mode cannot veto a call the user just allowed). Policy
/// pre-approvals (read class, Yolo mode) stay plain `Approve` and do NOT
/// count as consent.
///
/// Caching rules: `AllowSession`/`AllowAlways` remember an approval for the
/// rest of this agent's lifetime — **per tool name** for write-class and
/// unknown tools (approving `edit` once approves every later `edit`), and
/// **per command-segment scope** for shell tools: the command is split on
/// `&` `|` `;` newlines, a leading `rtk` is stripped (transparent wrapper),
/// each segment scopes to its first word (a non-transparent leading shim
/// like `sudo` refines to shim + next word, e.g. `bash:sudo rm`), and the
/// call is remembered only with *all* its segment scopes — approving
/// `moon check` never greenlights `git push` or a compound `... && rm`.
/// A shell call without a parseable `cmd` string is never remembered.
/// `AllowAlways` is session-scoped (no on-disk persistence).
pub(all) enum ApprovalDecision {
  /// Approve this one call only; do not cache.
  AllowOnce
  /// Approve and remember for the rest of this agent's lifetime (per the
  /// caching rules above).
  AllowSession
  /// Approve and remember; v0 equivalent to AllowSession (no persistence).
  AllowAlways
  /// Reject the call. With posoco's non-terminal hook rejection the denial
  /// is steering: the call is skipped, the reason returns to the model as a
  /// `NotExecuted(RejectedByHook)` tool result, and the turn continues —
  /// the model sees the denial and can explain, ask, or pick another tool
  /// (mainstream coding-agent semantics).
  Deny(reason~ : String)
}

///|
/// Host-implemented approval source. `ask` is `async` because
/// `Hook::before_tool` is `async`; a host that needs UI interaction (e.g.
/// the js host blocking on `UiPort::request` via `.wait()`) can suspend
/// inside `ask`. A host that decides synchronously implements `ask` as a
/// plain `fn` — a sync `fn` satisfies an `async` trait slot under MoonBit's
/// colorless-coroutine model.
pub(open) trait ApprovalSource {
  async fn ask(Self, request : ApprovalRequest) -> ApprovalDecision
}

// ──────────────────────────────────────────────────────────────────────────
// PermissionPolicy
// ──────────────────────────────────────────────────────────────────────────

///|
/// Classifies well-known coding tools and gates them through the approval
/// source. Construct once per agent; the same struct is the `PipelineHook`,
/// `CommandPort`, and `Extension`.
pub(all) struct PermissionPolicy {
  /// Active mode; mutable so `/permission <mode>` can switch at runtime.
  mut mode : PermissionMode
  /// None ⇒ behave as pure-mode (no approval prompt; ReadOnly rejects,
  /// WorkspaceWrite/Interactive would need a source). A None source on a
  /// non-ReadOnly mode treats every non-read tool as denied.
  approval : &ApprovalSource?
  /// Approvals remembered this agent lifetime, keyed by approval scope: the
  /// bare tool name for write/unknown tools, `"<tool>:<segment-scope>"` per
  /// shell command segment (e.g. `bash:ls`, `bash:moon` — a leading `rtk`
  /// is stripped; see `shell_scopes`). Approving `ls` must not approve
  /// `rm`.
  mut session_approved : Set[String]
  /// Tools reported exempt by composed extensions (bus topic
  /// `tool_exemptions`), keyed by tool name and remembering the reporting
  /// source id — exemptions self-identify as `source:name` so status and
  /// code review can see who vouched for what. They skip this gate
  /// entirely — trust channel, guaranteed by code review, not runtime
  /// checks.
  mut exempted : Map[String, String]
  read_tools : Array[String]
  write_tools : Array[String]
  shell_tools : Array[String]
}

///|
/// Construct a policy. `approval` is optional so a host can run ReadOnly
/// without wiring up a UI; non-ReadOnly modes without a source deny every
/// non-read tool. `bus`, when given, subscribes the policy to the
/// cross-extension event bus so peer extensions can report tools that
/// bypass this gate (topic `tool_exemptions`); construct subscribing gates
/// before the extensions that report to them — the bus is fire-and-forget.
pub fn PermissionPolicy::PermissionPolicy(
  mode : PermissionMode,
  approval? : &ApprovalSource? = None,
  bus? : @devkit.EventBus? = None,
) -> PermissionPolicy {
  let policy : PermissionPolicy = {
    mode,
    approval,
    session_approved: Set([]),
    exempted: Map::from_array([]),
    // ask_question rides the read class: it talks to the user and touches
    // nothing else — asking permission to ask a question is an extra
    // approval dialog before the actual question dialog. Skill activation
    // and resource reads only load instructions into context, so they ride
    // the read class too (these are the skills extension's default tool
    // names; a host that renames them must classify its own names).
    read_tools: [
      "read", "grep", "glob", "ask_question", "activate_skill", "read_skill_resource",
    ],
    write_tools: ["write", "edit", "apply_patch"],
    shell_tools: ["bash", "shell", "sh", "zsh", "cmd", "powershell"],
  }
  match bus {
    Some(bus) => bus.subscribe(policy as &@devkit.BusSubscriber)
    None => ()
  }
  policy
}

///|
/// Receive bus events. Only the `tool_exemptions` convention is
/// understood: a report records each tool name → the reporting extension's
/// id, and entries accumulate — there is no revocation. Everything else,
/// including malformed payloads, is ignored per the bus contract.
pub impl @devkit.BusSubscriber for PermissionPolicy with fn on_bus_event(
  self,
  event : @devkit.BusEvent,
) -> Unit {
  if event.topic == @devkit.tool_exemptions_topic {
    match @devkit.parse_tool_exemptions(event.data) {
      Some(names) =>
        for name in names {
          self.exempted[name] = event.source
        }
      None => ()
    }
  }
}

///|
/// Read-only accessor for the active mode.
pub fn PermissionPolicy::mode(self : PermissionPolicy) -> PermissionMode {
  self.mode
}

///|
/// Returns the per-turn reminder text for the active mode, wrapped in a
/// `<permission-context>` envelope so `before_model` can recognize and
/// deduplicate it. Dynamic because `/permission` can switch mode at runtime,
/// so this content is injected via `PipelineHook::before_model` rather than
/// the cached system prompt.
fn PermissionPolicy::mode_reminder_text(self : PermissionPolicy) -> String {
  let content = match self.mode {
    ReadOnly =>
      "Permission mode is read-only. Read-only shell commands (ls, cat, grep, git status, find) are pre-approved; file mutation and other shell execution are rejected."
    WorkspaceWrite =>
      "Permission mode allows workspace reads and writes. Read-only shell commands are pre-approved; other shell and unknown tools require host approval."
    Interactive =>
      "Permission mode is interactive. Read-only inspection — including read-only shell commands — is pre-approved; mutating, shell, and unknown tools require confirmation."
    Yolo =>
      "Permission mode is yolo: every tool call is pre-approved without confirmation. Proceed carefully."
  }
  @devkit.context_envelope(ns="permission", kind="mode", trust=true, content~)
}

///|
/// Classify a tool name into a category bucket.
fn PermissionPolicy::classify(self : PermissionPolicy, name : String) -> String {
  if self.read_tools.contains(name) {
    "read"
  } else if self.write_tools.contains(name) {
    "write"
  } else if self.shell_tools.contains(name) {
    "shell"
  } else {
    "unknown"
  }
}

///|
/// Truncate arguments to a bounded preview so the approval prompt stays
/// readable. Long payloads and secrets are clipped, not echoed in full.
fn preview_arguments(args : Json) -> String {
  let raw = args.stringify()
  if raw.length() <= 80 {
    raw
  } else {
    raw.sub(end=77).to_owned() + "..."
  }
}

///|
/// Shell shims whose first token is not the real command and which are not
/// transparent — they raise privileges (`sudo`, `doas`) or reshape the
/// executed command (`xargs`, `env`, …) — so they stay in the scope: it
/// refines to shim + next word, keeping `sudo rm` and `sudo ls` separate.
/// `rtk` is deliberately absent: it is a transparent project-local wrapper
/// and is stripped entirely by `segment_scope`.
let shell_shims : Array[String] = [
  "sudo", "doas", "env", "time", "nice", "nohup", "xargs", "watch",
]

///|
/// First one or two whitespace-delimited words of a single command segment —
/// the segment's approval scope. A leading `rtk` is stripped first: rtk is a
/// transparent project-local wrapper, so `rtk moon check` shares the `moon`
/// scope with a bare `moon check` (models guided by AGENTS.md and hosts
/// wiring posoco-ext-rtk both produce rtk-prefixed commands; either spelling
/// should honor one approval). Other leading shims refine to shim + next
/// word. v0 does not skip shim flags: `sudo -u root ls` scopes to `sudo -u`
/// (coarse but safe-ish: different flag spellings simply ask again). An
/// empty segment — or a bare `rtk` — has no scope.
fn segment_scope(segment : StringView) -> String? {
  let words : Array[String] = []
  let current = StringBuilder()
  for c in segment {
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      if current.to_string().length() > 0 {
        words.push(current.to_string())
        current.reset()
        // Three words cover `rtk <shim> <subcommand>`; the scope itself uses
        // at most two after the strip.
        if words.length() == 3 {
          break
        }
      }
    } else {
      current.write_char(c)
    }
  }
  if words.length() < 3 && current.to_string().length() > 0 {
    words.push(current.to_string())
  }
  let start = if words.length() > 0 && words[0] == "rtk" { 1 } else { 0 }
  if start == words.length() {
    None
  } else {
    let first = words[start]
    if start + 1 < words.length() && shell_shims.contains(first) {
      Some(first + " " + words[start + 1])
    } else {
      Some(first)
    }
  }
}

///|
/// All approval scopes of a shell command. The command is split into
/// compound/pipeline segments on `&`, `|`, `;`, and newlines (naive: a
/// separator inside quotes still splits, which only ever adds scopes and
/// therefore re-asks), and each segment contributes its scope. A command is
/// pre-approved only when *every* segment scope is remembered, so approving
/// `cd ok && ls` never greenlights `cd ok && rm -rf`.
fn shell_scopes(cmd : String) -> Array[String] {
  let scopes : Array[String] = []
  let segment = StringBuilder()
  fn flush() {
    match segment_scope(segment.to_string()[:]) {
      Some(scope) => if !scopes.contains(scope) { scopes.push(scope) }
      None => ()
    }
    segment.reset()
  }

  for c in cmd {
    if c == '&' || c == '|' || c == ';' || c == '\n' {
      flush()
    } else {
      segment.write_char(c)
    }
  }
  flush()
  scopes
}

///|
/// Cache keys under which an approval may be remembered; an empty array
/// means the call asks every time. Write and unknown tools scope to the
/// bare tool name — one "allow" covers that tool for the session. Shell
/// tools contribute one `"\<tool\>:\<scope\>"` key per command segment (see
/// `shell_scopes`); a shell call without a parseable `cmd` string yields no
/// keys and is never cached.
fn PermissionPolicy::cache_keys(
  _self : PermissionPolicy,
  call : @posoco.ToolCall,
  category : String,
) -> Array[String] {
  let name = call.name.to_string()
  if category == "shell" {
    match call.arguments {
      Object(obj) =>
        match obj.get("cmd") {
          Some(String(cmd)) =>
            shell_scopes(cmd).map(fn(scope) { "\{name}:\{scope}" })
          _ => []
        }
      _ => []
    }
  } else if category == "read" {
    []
  } else {
    [name]
  }
}

///|
/// Ask the approval source and apply its decision. Approvals surface as
/// `ApproveAfterConsent` — explicit user consent that outranks other
/// hooks' `Reject` in the pump's lattice. `async` because the source may
/// suspend on a UI confirm; classification itself is synchronous.
async fn PermissionPolicy::gate(
  self : PermissionPolicy,
  call : @posoco.ToolCall,
  category : String,
) -> @posoco.ToolDecision {
  let name = call.name.to_string()
  let keys = self.cache_keys(call, category)
  // Session cache hit: every approval scope of this call was already
  // remembered this session. Keyless calls (shell without a parseable
  // `cmd`) never hit and always ask.
  let mut all_approved = keys.length() > 0
  for k in keys {
    if !self.session_approved.contains(k) {
      all_approved = false
      break
    }
  }
  if all_approved {
    return @posoco.ToolDecision::ApproveAfterConsent(
      call~,
      consent_scope=keys.join("&"),
    )
  }
  match self.approval {
    None =>
      @posoco.ToolDecision::Reject(
        reason="permission: no approval source configured for '" + name + "'",
      )
    Some(source) => {
      let request : ApprovalRequest = {
        tool_name: name,
        call_id: call.call_id.to_string(),
        category,
        arguments_preview: preview_arguments(call.arguments),
        arguments: call.arguments,
      }
      match source.ask(request) {
        AllowOnce =>
          @posoco.ToolDecision::ApproveAfterConsent(
            call~,
            consent_scope=name + ":" + call.call_id.to_string(),
          )
        AllowSession | AllowAlways => {
          // Remember every approval scope of the call; keyless calls stay
          // per-call.
          for k in keys {
            self.session_approved.add(k)
          }
          let scope = if keys.length() > 0 { keys.join("&") } else { name }
          @posoco.ToolDecision::ApproveAfterConsent(call~, consent_scope=scope)
        }
        Deny(reason~) =>
          @posoco.ToolDecision::Reject(
            reason="permission: denied '" + name + "': " + reason,
          )
      }
    }
  }
}

///|
/// Provably read-only per `@devkit.shell_command_is_read_only` (conservative:
/// unknown commands are NOT read-only).
fn shell_call_is_read_only(call : @posoco.ToolCall) -> Bool {
  match call.arguments {
    Object(fields) =>
      match fields.get("cmd") {
        Some(String(cmd)) => @devkit.shell_command_is_read_only(cmd)
        _ => false
      }
    _ => false
  }
}

///|
/// Inject (or refresh) a single per-turn user message reminding the model of
/// the active permission mode. Idempotent: if the current mode's reminder is
/// already present, the transcript is unchanged. When `/permission` switches
/// mode, the existing reminder is replaced in place so the transcript stays
/// compact.
pub impl @posoco.PipelineHook for PermissionPolicy with fn before_model(
  self : PermissionPolicy,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  let reminder = self.mode_reminder_text()
  let prefix = "<permission-context"
  // Search for an existing permission-context user message.
  let mut existing_idx = -1
  let mut existing_text = ""
  for i, msg in messages {
    match msg {
      @kernel.Message::UserMessage(content~) =>
        match content {
          [@kernel.Content::Text(text), ..] =>
            if text.has_prefix(prefix) {
              existing_idx = i
              existing_text = text
              break
            }
          _ => ()
        }
      _ => ()
    }
  }
  if existing_idx < 0 {
    messages.push(
      @kernel.Message::UserMessage(content=[@kernel.Content::Text(reminder)]),
    )
  } else if existing_text != reminder {
    messages[existing_idx] = @kernel.Message::UserMessage(content=[
      @kernel.Content::Text(reminder),
    ])
  }
  messages
}

///|
pub impl @posoco.PipelineHook for PermissionPolicy with fn before_tool(
  self : PermissionPolicy,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  let name = call.name.to_string()
  // Exemption reports from composed extensions: these tools carry their
  // own governance and skip this gate entirely (trust: code review).
  if self.exempted.contains(name) {
    return @posoco.ToolDecision::Approve(call~)
  }
  let category = self.classify(name)
  // Provably read-only shell is inspection: pre-approved in every mode
  // without asking; anything unprovable falls through to the gate.
  if category == "shell" && shell_call_is_read_only(call) {
    return @posoco.ToolDecision::Approve(call~)
  }
  match self.mode {
    ReadOnly =>
      if category == "read" {
        @posoco.ToolDecision::Approve(call~)
      } else {
        @posoco.ToolDecision::Reject(
          reason="permission: read-only mode rejected tool '" + name + "'",
        )
      }
    WorkspaceWrite =>
      if category == "read" {
        @posoco.ToolDecision::Approve(call~)
      } else {
        // writes/shell/unknown go through the approval gate.
        self.gate(call, category)
      }
    Interactive =>
      if category == "read" {
        @posoco.ToolDecision::Approve(call~)
      } else {
        // every side-effecting tool goes through the approval gate.
        self.gate(call, category)
      }
    Yolo => @posoco.ToolDecision::Approve(call~)
  }
}

// ──────────────────────────────────────────────────────────────────────────
// /permission command
// ──────────────────────────────────────────────────────────────────────────

///|
fn PermissionPolicy::mode_name(self : PermissionPolicy) -> String {
  match self.mode {
    ReadOnly => "readonly"
    WorkspaceWrite => "workspace_write"
    Interactive => "interactive"
    Yolo => "yolo"
  }
}

///|
fn parse_mode_name(raw : String) -> PermissionMode? {
  match raw {
    "readonly" => Some(ReadOnly)
    "workspace_write" => Some(WorkspaceWrite)
    "interactive" => Some(Interactive)
    "yolo" => Some(Yolo)
    _ => None
  }
}

///|
/// Extract the optional action argument: `{action}`, a bare string, or the
/// host's `{_positional}` fallback for undeclared positional text.
fn parse_permission_action(args : Json) -> String? raise @posoco.CommandError {
  let invalid = fn(key : String) -> @posoco.CommandError {
    @posoco.CommandError::InvalidArgs(
      reason="/permission: '\{key}' must be a string",
    )
  }
  match args {
    Json::Null => None
    String(action) => if action.length() == 0 { None } else { Some(action) }
    Object(fields) =>
      match fields.get("action") {
        Some(String(value)) =>
          if value.length() == 0 {
            None
          } else {
            Some(value)
          }
        Some(_) => raise invalid("action")
        None =>
          match fields.get("_positional") {
            Some(String(value)) =>
              if value.length() == 0 {
                None
              } else {
                Some(value)
              }
            Some(_) => raise invalid("_positional")
            None => None
          }
      }
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/permission expects no arguments, an action string, or {action}",
      )
  }
}

///|
pub impl @posoco.CommandPort for PermissionPolicy with fn commands(_self) -> Array[
  @posoco.CommandDef,
] {
  [
    @posoco.CommandDef::{
      id: "permission",
      label: "Permission Mode",
      description: "Show or switch permission mode, or reset session approvals",
      category: "permission",
      ctype: @posoco.CommandType::Action,
      params: [
        @posoco.CommandParam::{
          name: "action",
          label: "Action",
          description: "status (default) / a mode name / reset",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: Some([
            "status", "readonly", "workspace_write", "interactive", "yolo", "reset",
          ]),
          positional: true,
        },
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
pub impl @posoco.CommandPort for PermissionPolicy with fn invoke(
  self,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "permission" =>
      match parse_permission_action(args) {
        None | Some("status") => {
          let approved = self.session_approved.to_array()
          let remembered = if approved.length() == 0 {
            "none"
          } else {
            approved.join(", ")
          }
          // Self-identifying entries: "source:name" shows who vouched for
          // each exemption.
          let exempted : Array[String] = []
          for name, source in self.exempted {
            exempted.push("\{source}:\{name}")
          }
          let exempt_list = if exempted.length() == 0 {
            "none"
          } else {
            exempted.join(", ")
          }
          let feedback = "permission mode: \{self.mode_name()} — session approvals: \{remembered} — exempted tools: \{exempt_list}"
          let structured : Json = {
            "mode": Json::string(self.mode_name()),
            "session_approvals": Json::array(approved.map(Json::string)),
            "exempted_tools": Json::array(exempted.map(Json::string)),
          }
          @posoco.CommandOutcome::Success(
            feedback~,
            structured=Some(structured),
            ui_hint=Some(@posoco.UiHint::Toast),
          )
        }
        Some("reset") => {
          self.session_approved.clear()
          @posoco.CommandOutcome::Success(
            feedback="session approvals cleared",
            structured=None,
            ui_hint=Some(@posoco.UiHint::Toast),
          )
        }
        Some(action) =>
          match parse_mode_name(action) {
            Some(mode) => {
              let previous = self.mode_name()
              self.mode = mode
              @posoco.CommandOutcome::Success(
                feedback="permission mode: " + previous + " → " + action,
                structured=None,
                ui_hint=Some(@posoco.UiHint::Toast),
              )
            }
            None =>
              @posoco.CommandOutcome::Failure(
                reason="unknown permission action '" +
                  action +
                  "' (expected status/readonly/workspace_write/interactive/yolo/reset)",
              )
          }
      }
    other => raise @posoco.CommandError::NotFound(other)
  }
}

///|
pub impl @posoco.Extension for PermissionPolicy with fn extension_id(
  _self : PermissionPolicy,
) -> String {
  "posoco_ext_permission"
}

///|
pub impl @posoco.Extension for PermissionPolicy with fn manifest(
  self : PermissionPolicy,
) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::empty(id="posoco_ext_permission")
  { ..manifest, hooks: [self], commands: [self] }
}

///|
pub extend PermissionPolicy with @posoco.Extension::{extension_id, manifest}
