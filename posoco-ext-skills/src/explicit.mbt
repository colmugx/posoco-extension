///|
/// explicit.mbt — harness-level explicit skill activation. A `$name` mention
/// of a discovered skill name anywhere in the turn's user input activates
/// that skill before any model call: this hook injects the SKILL.md
/// instructions as a trust-graded context envelope ahead of the user
/// message, produced by the same guarded activation path the model-facing
/// tool uses. Unknown `$tokens` are inert text. One prompt may mention
/// several skills; each is injected once, in first-appearance order.

///|
/// Opening tag of the envelope this hook injects. Doubles as the
/// idempotency marker: a trailing user-message run that already carries it
/// is left untouched, so hook registration order cannot double-inject.
const SKILL_ACTIVATION_ENVELOPE_PREFIX = "<cetas-context type=\"skill_activation\""

///|
fn is_skill_name_char(ch : Char) -> Bool {
  let alphanumeric = (ch >= 'a' && ch <= 'z') ||
    (ch >= 'A' && ch <= 'Z') ||
    (ch >= '0' && ch <= '9')
  alphanumeric || ch == '-' || ch == '_'
}

///|
/// Ordered, de-duplicated catalog names mentioned as `$name` tokens in
/// `text`. Token boundaries are non-name characters; a mention matches only
/// an exact catalog name, so shell text (`$PATH`, `awk '$1'`) stays inert.
fn Skills::scan_explicit_mentions(
  self : Skills,
  text : String,
) -> Array[String] {
  let found : Array[String] = []
  if self.catalog.skills.is_empty() {
    return found
  }
  let mut token = StringBuilder()
  let mut scanning = false
  for ch in text {
    if scanning {
      if is_skill_name_char(ch) {
        token.write_char(ch)
      } else {
        let name = token.to_string()
        if self.catalog.find(name) is Some(_) && !found.contains(name) {
          found.push(name)
        }
        scanning = false
      }
    } else if ch == '$' {
      scanning = true
      token = StringBuilder()
    }
  }
  if scanning {
    let name = token.to_string()
    if self.catalog.find(name) is Some(_) && !found.contains(name) {
      found.push(name)
    }
  }
  found
}

///|
/// Envelope body for one explicit activation. Success carries the exact
/// model-facing activation content; every failure path is surfaced in a
/// harness-voice error envelope instead of being dropped.
fn Skills::activation_envelope(
  self : Skills,
  name : String,
  outcome : @posoco.ToolOutcome,
) -> String {
  let scope = match self.catalog.find(name) {
    Some(skill) => scope_label(skill.scope)
    None => ""
  }
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) =>
      @devkit.context_envelope(
        ns="cetas",
        kind="skill_activation",
        trust=false,
        source="skill:" + name,
        attrs=[("invocation", "explicit"), ("scope", scope)],
        content~,
      )
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      @devkit.context_envelope(
        ns="cetas",
        kind="skill_activation_error",
        trust=true,
        source="skill:" + name,
        attrs=[("invocation", "explicit")],
        content="Skill '" +
          name +
          "' was mentioned explicitly but could not be activated: " +
          content,
      )
    _ =>
      @devkit.context_envelope(
        ns="cetas",
        kind="skill_activation_error",
        trust=true,
        source="skill:" + name,
        attrs=[("invocation", "explicit")],
        content="Skill '" +
          name +
          "' was mentioned explicitly but activation did not complete.",
      )
  }
}

///|
/// Harness-level explicit activation. Fires when the transcript's trailing
/// user-message run (the turn input, plus any user-role envelopes other
/// hooks appended after it) mentions discovered skills: one message
/// carrying all activation envelopes is inserted ahead of that run, so the
/// user's text itself stays untouched. Per-model-step dispatch is safe —
/// steps after tool execution end on a ToolMessage, not the user input.
impl @posoco.PipelineHook for Skills with fn before_model(
  self : Skills,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  let mut start = messages.length()
  while start > 0 {
    match messages[start - 1] {
      @posoco.Message::UserMessage(..) => start = start - 1
      _ => break
    }
  }
  if start == messages.length() {
    return messages
  }
  let text_all = StringBuilder()
  for i in start..<messages.length() {
    match messages[i] {
      @posoco.Message::UserMessage(content~) =>
        for block in content {
          match block {
            @posoco.Content::Text(text) => {
              if text.has_prefix(SKILL_ACTIVATION_ENVELOPE_PREFIX) {
                return messages
              }
              text_all.write_string(text)
              text_all.write_string("\n")
            }
            _ => ()
          }
        }
      _ => ()
    }
  }
  let names = self.scan_explicit_mentions(text_all.to_string())
  if names.is_empty() {
    return messages
  }
  let envelopes = StringBuilder()
  let activated : Array[String] = []
  for name in names {
    let outcome = self.activate(name)
    match outcome {
      @posoco.ToolOutcome::Success(..) => activated.push(name)
      _ => ()
    }
    envelopes.write_string(self.activation_envelope(name, outcome))
    envelopes.write_string("\n\n")
  }
  // Harness voice, outside the escaped envelopes: the model must not
  // re-activate skills whose instructions this message already carries.
  if !activated.is_empty() {
    envelopes.write_string("(Skill")
    if activated.length() > 1 {
      envelopes.write_string("s")
    }
    envelopes.write_string(
      " " +
      activated.join(", ") +
      " above were activated by the `$name` mentions in this request; their instructions are already loaded, so do not call " +
      self.config.activate_tool_name +
      " for them again.)\n",
    )
  }
  let injected = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(envelopes.to_string()),
  ])
  let rewritten : Array[@posoco.Message] = []
  for i in 0..<messages.length() {
    if i == start {
      rewritten.push(injected)
    }
    rewritten.push(messages[i])
  }
  rewritten
}

///|
pub extend Skills with @posoco.PipelineHook::{before_model}
