///|
/// SSE streaming for the standard OpenAI Chat Completions wire.
///
/// The parser is shared across chat-completions providers in
/// posoco-kit-chat-completions; this wrapper pins the `custom` provider label
/// used in every raised message. See the kit for the tolerance policy.

///|
/// Parse one SSE data line into StreamChunk(s) and feed to accumulator.
/// Returns true when the stream is finished ([DONE] or finish_reason present).
fn process_custom_chat_sse(
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool raise @posoco.ModelError {
  @chatkit.process_chat_completions_sse(provider="custom", data, acc, on_chunk)
}
