///|
/// The two fail-closed stream bounds and their evaluation order.

///|
test "the reasoning ceiling is a strict character bound" {
  assert_false(reasoning_limit_exceeded(100, 100))
  assert_true(reasoning_limit_exceeded(101, 100))
  assert_false(reasoning_limit_exceeded(0, 100))
}

///|
test "exact repeated reasoning suffix requires three long repeats" {
  let a = "a".repeat(128)
  let b = "b".repeat(128)
  assert_false(has_repeated_reasoning_suffix(a + a, 128))
  assert_true(has_repeated_reasoning_suffix(a + a + a, 128))
  assert_false(has_repeated_reasoning_suffix(a + b + a, 128))
  // Below the floor the span is never judged, even for a perfect repeat.
  assert_false(has_repeated_reasoning_suffix(a + a + a, 64))
}

///|
test "the suffix detector measures Unicode text by character" {
  let chinese = "思考过程".repeat(128)
  assert_true(
    has_repeated_reasoning_suffix(chinese + chinese + chinese, chinese.length()),
  )
}

///|
fn guarded_accumulator(reasoning : String) -> @posoco.StreamAccumulator raise {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  acc.push(@posoco.StreamChunk::ReasoningDelta(token=reasoning))
  acc
}

///|
test "suffix detection does not panic when a UTF-16 window splits an emoji" {
  // UTF-16 boundaries for n=768, span=256: 0, 256, 512, 768.
  // The emoji occupies code units [511, 513), so offset 512 splits the pair.
  let reasoning = "a".repeat(511) + "\u{1F600}" + "b".repeat(255)
  assert_eq(reasoning.length(), 768)
  assert_false(has_repeated_reasoning_suffix(reasoning, 256))
}

///|
test "suffix detection still finds repetition with aligned emoji boundaries" {
  let suffix = "a".repeat(254) + "\u{1F600}"
  assert_eq(suffix.length(), 256)
  assert_true(has_repeated_reasoning_suffix(suffix + suffix + suffix, 256))
}

///|
test "suffix detection rejects span sizes that overflow a 32-bit product" {
  assert_false(has_repeated_reasoning_suffix("x".repeat(768), 2147483647))
}

///|
test "observe reports a budget breach past the ceiling" {
  let policy = DeepSeekPolicy(
    max_reasoning_chars=Some(10),
    repeated_reasoning_span_chars=None,
    recover_on_reasoning_exhaustion=false,
  )
  let acc = guarded_accumulator("0123456789a")
  assert_eq(policy.observe(acc, done=false), Some(BudgetExceeded))
  assert_eq(
    ReasoningBreach::category(BudgetExceeded),
    "reasoning_budget_exceeded",
  )
}

///|
test "observe never re-judges a completed stream" {
  let span = "x".repeat(128)
  let repetition_policy = DeepSeekPolicy(
    max_reasoning_chars=Some(120000),
    repeated_reasoning_span_chars=Some(128),
    recover_on_reasoning_exhaustion=false,
  )
  let acc = guarded_accumulator(span + span + span)
  // Not done: the repetition guard fires before any answer text exists.
  assert_eq(
    repetition_policy.observe(acc, done=false),
    Some(RepetitionDetected),
  )
  // Done: a finished answer is legitimate regardless of its reasoning shape.
  let finished = guarded_accumulator(span + span + span)
  assert_true(repetition_policy.observe(finished, done=true) is None)
  // The ceiling is a resource cap, not a completion judgement: it still
  // applies to the final event, exactly as the direct adapter behaves.
  let budget_policy = DeepSeekPolicy(
    max_reasoning_chars=Some(10),
    repeated_reasoning_span_chars=None,
    recover_on_reasoning_exhaustion=false,
  )
  assert_eq(budget_policy.observe(finished, done=true), Some(BudgetExceeded))
}

///|
test "observe ignores reasoning repetition once answer text exists" {
  let span = "y".repeat(128)
  let policy = DeepSeekPolicy(
    max_reasoning_chars=Some(120000),
    repeated_reasoning_span_chars=Some(128),
    recover_on_reasoning_exhaustion=false,
  )
  let acc = guarded_accumulator(span + span + span)
  acc.push(@posoco.StreamChunk::TextDelta(token="answer"))
  assert_true(policy.observe(acc, done=false) is None)
}

///|
test "a disabled policy observes nothing" {
  let span = "z".repeat(128)
  let acc = guarded_accumulator(span + span + span)
  assert_true(DeepSeekPolicy::disabled().observe(acc, done=false) is None)
}
