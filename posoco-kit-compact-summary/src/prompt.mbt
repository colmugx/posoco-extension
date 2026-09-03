///|
/// Assemble the messages for one summarize call.
///
/// Returns `[SystemMessage(template instruction), UserMessage(payload)]`
/// where the payload wraps the serialized conversation in
/// `<conversation>...</conversation>`, optionally carries the previous
/// summary in `<previous-summary>...</previous-summary>` (progressive
/// anchoring: merge still-true facts, drop stale ones), then the template's
/// output requirement, and optionally an `Additional focus:` line with the
/// caller's custom instruction. The LLM call itself is orchestrated by the
/// adapter, not by this kit.
pub fn build_summary_prompt(
  template : SummaryTemplate,
  conversation_text : String,
  previous_summary? : String? = None,
  custom_instruction? : String? = None,
) -> Array[@posoco.Message] {
  let mut user = "<conversation>\n" +
    conversation_text +
    "\n</conversation>\n\n"
  match previous_summary {
    Some(prev) =>
      user = user + "<previous-summary>\n" + prev + "\n</previous-summary>\n\n"
    None => ()
  }
  user = user + template_user_requirement(template)
  match custom_instruction {
    Some(focus) => user = user + "\nAdditional focus: " + focus
    None => ()
  }
  let messages : Array[@posoco.Message] = [
    SystemMessage(content=[Text(template_system_instruction(template))]),
    UserMessage(content=[Text(user)]),
  ]
  messages
}
