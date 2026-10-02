///|
fn compact_internal_or_legacy_context(text : String) -> Bool {
  let text = text.trim().to_owned()
  if text.has_prefix(
      "Warning: The maximum number of unified exec processes you can keep open is",
    ) ||
    text.has_prefix(
      "Warning: Your account was flagged for potentially high-risk cyber activity",
    ) {
    return true
  }
  if text.has_prefix("Warning: apply_patch was requested via ") &&
    text.has_suffix("Use the apply_patch tool instead of exec_command.") {
    return true
  }
  if text.has_prefix("<goal_context>") && text.has_suffix("</goal_context>") {
    return true
  }
  if text.has_prefix("<external_") {
    match text.find(">") {
      Some(end) =>
        if text.has_suffix("</external_" + text[10:end].to_owned() + ">") {
          return true
        }
      None => ()
    }
  }
  let open = "<codex_internal_context source=\""
  if !text.has_prefix(open) || !text.has_suffix("</codex_internal_context>") {
    return false
  }
  let rest = text[open.length():]
  guard rest.find("\">") is Some(end) else { return false }
  let source = rest[:end]
  if source.is_empty() {
    return false
  }
  let mut first = true
  for ch in source {
    if first {
      if ch < 'a' || ch > 'z' {
        return false
      }
      first = false
    } else if !((ch >= 'a' && ch <= 'z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_') {
      return false
    }
  }
  true
}

///|
/// Cetas has no typed HookPrompt; recognize its official persisted wrapper
/// without manufacturing hook provenance for ordinary user messages.
fn compact_visible_hook_text(text : String) -> Bool {
  let text = text.trim().to_owned()
  let open = "<hook_prompt hook_run_id=\""
  if !text.has_prefix(open) || !text.has_suffix("</hook_prompt>") {
    return false
  }
  let rest = text[open.length():]
  guard rest.find("\">") is Some(end) else { return false }
  !rest[:end].trim().is_empty()
}

///|
/// ModelInfo serde default: absent metadata is false, never a slug guess.
fn model_responses_lite(
  fields : Map[String, Json],
) -> Bool raise @posoco.ModelError {
  match fields.get("use_responses_lite") {
    Some(Json::True) => true
    Some(Json::False) | None => false
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI models use_responses_lite must be a boolean",
      )
  }
}
