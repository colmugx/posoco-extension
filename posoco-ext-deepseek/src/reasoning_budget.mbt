///|
/// A deterministic guard on accumulated reasoning characters, not tokens.
/// Only applies to streaming responses; the caller must treat breach as a
/// transport failure and never turn a truncated stream into a completion.
fn deepseek_reasoning_limit_exceeded(chars : Int, limit : Int) -> Bool {
  chars > limit
}
