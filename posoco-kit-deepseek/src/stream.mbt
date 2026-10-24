///|
/// A streaming reasoning breach. DeepSeek's decode path has no client-visible
/// token budget: the server keeps thinking for as long as it keeps producing
/// new reasoning. A client that never bounds that stream pays for it twice —
/// once in latency, once in the wasted window it must then compact. Both
/// breaches are fail-closed: the caller closes the connection and raises a
/// transport error rather than turning a truncated stream into a completion.
pub(all) enum ReasoningBreach {
  /// The accumulated reasoning passed `max_reasoning_chars`.
  BudgetExceeded
  /// The streamed reasoning ended in three identical, long suffixes — a
  /// deterministic degeneracy signal, not a semantic one.
  RepetitionDetected
} derive(Eq, Debug)

///|
pub extend ReasoningBreach with Eq::{not_equal, equal}

///|
pub extend ReasoningBreach with Debug::{to_repr}

///|
/// Stable category token for error messages and logs. Callers embed it in
/// their own error text so the vocabulary survives a transport rewrite.
pub fn ReasoningBreach::category(self : ReasoningBreach) -> String {
  match self {
    BudgetExceeded => "reasoning_budget_exceeded"
    RepetitionDetected => "reasoning_repetition"
  }
}

///|
pub fn ReasoningBreach::message(self : ReasoningBreach) -> String {
  match self {
    BudgetExceeded =>
      "DeepSeek reasoning stream exceeded configured max_reasoning_chars"
    RepetitionDetected => "DeepSeek stream reasoning repetition detected"
  }
}

///|
/// Observe the accumulator after each SSE event. The caller passes `done`
/// because a completed stream must never be re-judged: a finished response
/// whose reasoning happens to end repetitively is a legitimate answer, and
/// the DeepSeek fix for exactly that false positive is encoded here.
///
/// Order matters and mirrors the serving behaviour: repetition is only
/// meaningful before any answer text exists, then the character ceiling
/// applies to the whole reasoning transcript.
pub fn DeepSeekPolicy::observe(
  self : DeepSeekPolicy,
  acc : @posoco.StreamAccumulator,
  done~ : Bool,
) -> ReasoningBreach? {
  if !done && acc.text().length() == 0 {
    match self.repeated_reasoning_span_chars {
      Some(span) =>
        if has_repeated_reasoning_suffix(acc.reasoning(), span) {
          return Some(RepetitionDetected)
        }
      None => ()
    }
  }
  match self.max_reasoning_chars {
    Some(limit) =>
      if reasoning_limit_exceeded(acc.reasoning().length(), limit) {
        return Some(BudgetExceeded)
      }
    None => ()
  }
  None
}

///|
/// A deterministic guard on accumulated reasoning characters, not tokens.
pub fn reasoning_limit_exceeded(chars : Int32, limit : Int32) -> Bool {
  chars > limit
}

///|
/// Detect only exact suffix repetition, not semantic stagnation. The final
/// three consecutive spans must be identical; input is already accumulated
/// reasoning. A large window limits false positives from common short
/// phrases, and spans smaller than 128 characters are never judged.
pub fn has_repeated_reasoning_suffix(
  reasoning : String,
  span_chars : Int32,
) -> Bool {
  let n = reasoning.length()
  // String.length counts UTF-16 code units. Avoid multiplying a user-supplied
  // span before checking it: large spans can overflow Int32.
  if span_chars < 128 || span_chars > n / 3 {
    return false
  }
  // A streamed reasoning suffix may contain supplementary Unicode characters
  // (e.g. emoji). Fixed UTF-16 offsets can bisect their surrogate pairs;
  // exact_view would panic and terminate the host. A split window cannot
  // prove exact repetition, so skip this observation instead.
  guard reasoning.get_view(start=n - span_chars * 3, end=n - span_chars * 2)
    is Some(a) else {
    return false
  }
  guard reasoning.get_view(start=n - span_chars * 2, end=n - span_chars)
    is Some(b) else {
    return false
  }
  guard reasoning.get_view(start=n - span_chars) is Some(c) else {
    return false
  }
  a == b && b == c
}
