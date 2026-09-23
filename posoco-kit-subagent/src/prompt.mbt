///|
/// Hard cap on caller-supplied `instructions` (design §9.6): trust annotation
/// plus delimited rendering is the whole defense, so length is bounded.
const MAX_INSTRUCTIONS_CHARS = 8192

///|
/// System-prompt assembly failures.
pub(all) suberror PromptAssemblyError {
  /// Caller instructions exceed the §9.6 hard limit; the message carries the
  /// actual length and the cap.
  InstructionsTooLong(String)
}

///|
/// Assemble a subagent system prompt (design §2.3): the kind template body is
/// the base, and caller `instructions` fill the `{{instructions}}` slot.
/// Non-empty instructions are wrapped in a trust-annotated
/// `<subagent-context>` envelope (devkit `context_envelope`) so the filled
/// content cannot impersonate the template's own voice; empty or absent
/// instructions bind the empty string, leaving the template's `<fillin>`
/// region visibly empty. Instructions longer than 8192 characters are
/// rejected, not truncated.
pub fn assemble_system_prompt(
  kind : @kind.KindSpec,
  instructions? : String,
) -> String raise PromptAssemblyError {
  let text = match instructions {
    Some(text) => text
    None => ""
  }
  if text.length() > MAX_INSTRUCTIONS_CHARS {
    raise PromptAssemblyError::InstructionsTooLong(
      "instructions length \{text.length()} exceeds the \{MAX_INSTRUCTIONS_CHARS}-character limit",
    )
  }
  let filled = if text.is_empty() {
    ""
  } else {
    @devkit.context_envelope(
      ns="subagent",
      kind="instructions",
      trust=true,
      source="caller",
      content=text,
    )
  }
  @kind.render_kind_body(kind.body, [("instructions", filled)])
}

///|
/// Render one swarm member's task: `{{item}}` placeholders in the template
/// are replaced with the item text (via the kind renderer, so repeated
/// placeholders are all substituted).
pub fn render_swarm_task(template : String, item : String) -> String {
  @kind.render_kind_body(template, [("item", item)])
}
