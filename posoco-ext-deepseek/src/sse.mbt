///|
/// SSE streaming for DeepSeek chat completions.
///
/// The parser is shared across chat-completions providers in
/// posoco-kit-chat-completions; this wrapper pins the "DeepSeek" prefix used
/// in every raised message. See the kit for the tolerance policy.

///|
/// Parse one SSE data line into StreamChunk(s) and feed to accumulator.
/// Returns true when the stream is finished ([DONE] or finish_reason present).
fn process_deepseek_sse(
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool raise @posoco.ModelError {
  @chatkit.process_chat_completions_sse(
    provider="DeepSeek",
    usage_fields_required=true,
    data,
    acc,
    on_chunk,
  )
}
