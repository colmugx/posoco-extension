///|
/// SSE streaming for z.ai chat completions. The parser is shared across
/// chat-completions providers in posoco-kit-chat-completions; this wrapper
/// pins the "zai" prefix used in every raised message.

///|
/// Parse one SSE data line into StreamChunk(s) and feed to accumulator.
/// Returns true when the stream is finished ([DONE] or finish_reason present).
fn process_zai_sse(
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool raise @posoco.ModelError {
  @chatkit.process_chat_completions_sse(provider="zai", data, acc, on_chunk)
}
