///|
/// Anchor prefix of the user message that carries a summary in a
/// Replace-mode result. Both this kit's own products and later turns
/// recognize prior summaries by this prefix (progressive anchoring).
///
/// Working value; the final wording is a deferred product decision.
pub const SUMMARY_PREFIX : String = "Previous context has been compacted. Here is the summary of the earlier conversation:"

///|
/// Whether `message` is a summary message produced by `build_replace_result`
/// (or any user message whose first Text block starts with `SUMMARY_PREFIX`).
pub fn is_summary_message(message : @posoco.Message) -> Bool {
  match message {
    UserMessage(content~) => {
      for block in content {
        match block {
          Text(text) => return text.has_prefix(SUMMARY_PREFIX)
          Image(..) => ()
        }
      }
      false
    }
    _ => false
  }
}

///|
/// Package a summary and the kept tail into a Replace-mode result: the
/// summary becomes one user message headed by `SUMMARY_PREFIX`, followed by
/// the tail messages verbatim. `tail_messages` is not mutated.
pub fn build_replace_result(
  summary : String,
  tail_messages : Array[@posoco.Message],
) -> @posoco.CompactResult {
  let compacted : Array[@posoco.Message] = [
    UserMessage(content=[Text(SUMMARY_PREFIX + "\n\n" + summary)]),
  ]
  for message in tail_messages {
    compacted.push(message)
  }
  @posoco.CompactResult::{
    compacted_messages: compacted,
    mode: @posoco.CompactMode::Replace,
  }
}
