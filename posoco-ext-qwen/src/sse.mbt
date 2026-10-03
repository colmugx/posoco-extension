///|
fn process_qwen_sse(
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool raise @posoco.ModelError {
  @chatkit.process_chat_completions_sse(provider="qwen", data, acc, on_chunk)
}
