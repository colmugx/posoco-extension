///|
/// A non-streaming retry is safe only when the response is unusable:
/// the provider stopped at length, emitted no answer, and requested no tools.
/// Never replay successful work, partial text, or actionable tool calls.
fn deepseek_can_retry_reasoning_exhaustion(
  completion : @posoco.Completion,
) -> Bool {
  completion.finish_reason() is @posoco.FinishReason::Length &&
  completion.message.content.length() == 0 &&
  completion.tool_calls().length() == 0
}

///|
/// Detect only exact suffix repetition, not semantic stagnation. The final
/// three consecutive spans must be identical; input is already accumulated
/// reasoning. A large window limits false positives from common short phrases.
fn deepseek_has_repeated_reasoning_suffix(
  reasoning : String,
  span_chars : Int32,
) -> Bool {
  if span_chars < 128 || reasoning.length() < span_chars * 3 {
    return false
  }
  let n = reasoning.length()
  let a = reasoning.exact_view(start=n - span_chars * 3, end=n - span_chars * 2)
  let b = reasoning.exact_view(start=n - span_chars * 2, end=n - span_chars)
  let c = reasoning.exact_view(start=n - span_chars)
  a == b && b == c
}
