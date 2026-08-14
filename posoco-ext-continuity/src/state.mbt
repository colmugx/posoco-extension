///|
/// Runtime checkpoint candidate bound to one canonical Posoco invocation.
/// The model receives only `id`; the source range and messages remain
/// extension-owned so the model cannot choose what gets folded.
pub(all) struct RuntimeCandidate {
  id : String
  session_id : String
  run_id : String
  start_index : Int
  end_index : Int
  estimated_tokens : Int
  source_messages : Array[@posoco.Message]
} derive(Eq, Debug)

///|
/// A checkpoint that has already archived its source messages and is waiting
/// for the next `Hook::before_model` boundary to rewrite the canonical
/// transcript.
pub(all) struct PreparedCheckpoint {
  checkpoint_id : String
  candidate : RuntimeCandidate
  summary : CheckpointSummary
} derive(Eq, Debug)

///|
fn copy_message_range(
  messages : Array[@posoco.Message],
  start : Int,
  end : Int,
) -> Array[@posoco.Message] {
  let out : Array[@posoco.Message] = []
  let mut i = start
  while i < end && i < messages.length() {
    out.push(messages[i])
    i = i + 1
  }
  out
}

///|
fn range_matches(
  messages : Array[@posoco.Message],
  candidate : RuntimeCandidate,
) -> Bool {
  if candidate.start_index < 0 ||
    candidate.end_index < candidate.start_index ||
    candidate.end_index > messages.length() {
    return false
  }
  let expected = candidate.source_messages
  if expected.length() != candidate.end_index - candidate.start_index {
    return false
  }
  let mut i = 0
  while i < expected.length() {
    if messages[candidate.start_index + i] != expected[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
fn checkpoint_message(
  checkpoint_id : String,
  summary : CheckpointSummary,
) -> @posoco.Message {
  @posoco.Message::SystemMessage(content=[
    @posoco.Content::Text(summary.render(checkpoint_id)),
  ])
}

///|
/// Replace exactly the candidate range with one system-owned checkpoint.
/// Returns `None` when the source range no longer matches; callers must keep
/// the canonical transcript unchanged in that case.
fn apply_prepared_checkpoint(
  messages : Array[@posoco.Message],
  prepared : PreparedCheckpoint,
) -> Array[@posoco.Message]? {
  let candidate = prepared.candidate
  if !range_matches(messages, candidate) {
    return None
  }
  let out : Array[@posoco.Message] = []
  let mut i = 0
  while i < candidate.start_index {
    out.push(messages[i])
    i = i + 1
  }
  out.push(checkpoint_message(prepared.checkpoint_id, prepared.summary))
  i = candidate.end_index
  while i < messages.length() {
    out.push(messages[i])
    i = i + 1
  }
  Some(out)
}
