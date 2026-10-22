///|
/// A non-streaming retry is safe only when the response is unusable: the
/// provider stopped at length, emitted no answer, and requested no tools.
/// Never replay successful work, partial text, or actionable tool calls —
/// those already reached the host and cannot be retracted.
pub fn can_retry_reasoning_exhaustion(completion : @posoco.Completion) -> Bool {
  completion.finish_reason() is @posoco.FinishReason::Length &&
  completion.message.content.length() == 0 &&
  completion.tool_calls().length() == 0
}
