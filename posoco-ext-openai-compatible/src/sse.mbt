///|
/// SSE streaming for standard OpenAI Chat Completions.
///
/// The parser is shared across chat-completions providers in
/// posoco-kit-chat-completions; this wrapper pins the "openai-compatible"
/// prefix used in every raised message. See the kit for the tolerance policy.

///|
/// Parse one SSE data line into StreamChunk(s) and feed to accumulator.
/// Returns true when the stream is finished ([DONE] or finish_reason present).
fn process_oai_compat_sse(
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool raise @posoco.ModelError {
  @chatkit.process_chat_completions_sse(
    provider="openai-compatible",
    data,
    acc,
    on_chunk,
  )
}
