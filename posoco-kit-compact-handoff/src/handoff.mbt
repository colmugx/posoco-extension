// handoff.mbt — NewThread handoff: the summary enters a fresh session as the
// first user message, followed by the caller-chosen tail messages; the body
// also carries the old session's persisted transcript path so the model can
// grep/read it to recover full context.

///|
/// Working preamble identifying the first user message of a handoff thread.
pub const HANDOFF_PREFIX : String = "This session continues from a previous conversation that was compacted. Summary of the earlier work:"

///|
/// Default tail-of-body hint: how to recover the old transcript from disk.
pub fn default_retrieval_hint() -> String {
  "The full transcript of that earlier session was persisted to the path above. You can search the old session file (e.g. with grep/read) to recover the full context."
}

///|
/// Build the NewThread handoff product: one user message carrying the
/// summary, the parent session path and the retrieval hint, followed by the
/// given tail messages verbatim. Inputs are never mutated.
///
/// `tail_turns` is declared only at this stage: range-checked to 1..=20 with
/// fallback to the default; actual tail selection is the caller's job.
pub fn build_handoff_result(
  summary : String,
  tail_messages : Array[@posoco.Message],
  parent_session_path : String,
  retrieval_hint? : String = default_retrieval_hint(),
  tail_turns? : Int = 3,
) -> @posoco.CompactResult {
  ignore(if tail_turns >= 1 && tail_turns <= 20 { tail_turns } else { 3 })
  let body = HANDOFF_PREFIX +
    "\n\n" +
    summary +
    "\n\n" +
    "Previous session transcript (searchable): " +
    parent_session_path +
    "\n\n" +
    retrieval_hint
  let compacted : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text(body)]),
  ]
  for message in tail_messages {
    compacted.push(message)
  }
  @posoco.CompactResult::{
    compacted_messages: compacted,
    mode: @posoco.CompactMode::NewThread,
  }
}

///|
/// Join `base_dir` and `session_id` with a single slash, collapsing any
/// duplicate slashes either side contributes.
pub fn handoff_session_path(base_dir : String, session_id : String) -> String {
  let builder = StringBuilder()
  let mut prev_slash = false
  for ch in base_dir + "/" + session_id {
    if ch == '/' {
      if !prev_slash {
        builder.write_char(ch)
      }
      prev_slash = true
    } else {
      builder.write_char(ch)
      prev_slash = false
    }
  }
  builder.to_string()
}
