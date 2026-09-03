///|
/// trim.mbt — posoco-kit-compact-trim: deterministic, LLM-free compact
/// fallback for overflow recovery. Drops whole conversation rounds from the
/// front (never the leading SystemMessage) until the estimated token total
/// fits the target budget.

///|
/// Why trim_fallback refused to produce a compact result.
pub(all) enum TrimError {
  /// Input already fits the budget; nothing to trim.
  AlreadyWithinBudget
  /// No valid trim exists that is strictly smaller than the input
  /// (no droppable round, or every droppable round carries zero tokens).
  NoProgress
  /// Input message array is empty.
  EmptyInput
} derive(Eq, Debug)

///|
/// ceil(chars / 4) without floating point.
fn ceil_div4(chars : Int) -> Int {
  (chars + 3) / 4
}

///|
/// Visible character count of one content block array.
/// Text blocks count verbatim; an image block counts only its media_type
/// string — the binary payload is invisible to the transcript reader and
/// would otherwise dominate the estimate. String length is counted in
/// UTF-16 code units (the String::length unit), a good-enough "visible
/// character" approximation for a 4-chars-per-token heuristic.
fn content_chars(content : Array[@posoco.Content]) -> Int {
  let mut total = 0
  for block in content {
    match block {
      Text(text) => total += text.length()
      Image(media_type~, ..) => total += media_type.length()
    }
  }
  total
}

///|
/// Visible character count of one message:
/// - System/User/Assistant: Text content chars; an assistant's tool calls
///   add the tool name plus its arguments serialized as JSON.
/// - Tool: the outcome's textual payload (success/error content, runtime
///   failure message, or the not-executed reason rendered as string).
/// Assistant `reasoning` is not visible transcript content and is not counted.
fn message_chars(message : @posoco.Message) -> Int {
  let mut total = 0
  match message {
    SystemMessage(content~) => total += content_chars(content)
    UserMessage(content~) => total += content_chars(content)
    AssistantMessage(content~, tool_calls~, ..) => {
      total += content_chars(content)
      for call in tool_calls {
        total += call.name.to_string().length()
        total += call.arguments.stringify().length()
      }
    }
    ToolMessage(outcome~, ..) =>
      match outcome {
        Success(content~, ..) => total += content.length()
        ToolReportedError(content~, ..) => total += content.length()
        RuntimeFailure(message~, ..) => total += message.length()
        NotExecuted(reason~, ..) => total += reason.to_string().length()
      }
  }
  total
}

///|
/// Deterministic token estimate for a message array: each message
/// contributes ceil(its visible chars / 4), and the total is the sum of
/// those per-message values (additive, so cut-point arithmetic and the
/// strict-shrink check measure the same quantity).
pub fn estimate_tokens(messages : Array[@posoco.Message]) -> Int {
  let mut total = 0
  for message in messages {
    total += ceil_div4(message_chars(message))
  }
  total
}

///|
/// Deterministic compact fallback: drop whole rounds from the front until
/// the estimated total fits `target_tokens`.
///
/// A round is one UserMessage plus everything up to (not including) the
/// next UserMessage. The cut point only ever lands immediately before a
/// UserMessage, so an AssistantMessage and its following ToolMessages are
/// never separated. The leading run of SystemMessages is never dropped.
/// Messages sitting between the system prefix and the first UserMessage
/// (orphans) are therefore also retained — they cannot be reached by any
/// legal cut. The input array is never mutated; the result is a new array.
///
/// Errors: `EmptyInput` for an empty array; `AlreadyWithinBudget` when the
/// input already fits; `NoProgress` when no legal cut yields a result
/// strictly smaller than the input. When even the maximal trim cannot
/// reach the budget but is strictly smaller than the input, that maximal
/// trim is returned as `Ok` — real progress beats giving up.
pub fn trim_fallback(
  messages : Array[@posoco.Message],
  target_tokens : Int,
) -> Result[@posoco.CompactResult, TrimError] {
  if messages.is_empty() {
    return Err(TrimError::EmptyInput)
  }
  let input_tokens = estimate_tokens(messages)
  if input_tokens <= target_tokens {
    return Err(TrimError::AlreadyWithinBudget)
  }
  let n = messages.length()
  // Protected head: the leading run of SystemMessages.
  let mut sys_end = 0
  while sys_end < n {
    if messages[sys_end] is SystemMessage(..) {
      sys_end += 1
    } else {
      break
    }
  }
  // prefix[i] = estimated tokens of messages[0..i]; prefix[n] == input_tokens.
  let prefix : Array[Int] = Array::make(n + 1, 0)
  for i in 0..<n {
    prefix[i + 1] = prefix[i] + ceil_div4(message_chars(messages[i]))
  }
  let total = prefix[n]
  let head_tokens = prefix[sys_end]
  // Smallest legal cut (first UserMessage after the system prefix) whose
  // kept total fits the budget. Kept tokens for a cut at i:
  // head_tokens + (total - prefix[i]).
  let mut fit_cut : Int? = None
  let mut i = sys_end
  while i < n {
    if messages[i] is UserMessage(..) {
      if head_tokens + total - prefix[i] <= target_tokens {
        fit_cut = Some(i)
        break
      }
    }
    i += 1
  }
  let cut : Int? = match fit_cut {
    Some(c) => Some(c)
    None =>
      // Budget unreachable with any legal cut. Take the maximal trim
      // (largest cut) if it still shrinks the transcript.
      match last_user_cut(messages, sys_end) {
        Some(c) =>
          if head_tokens + total - prefix[c] < input_tokens {
            Some(c)
          } else {
            None
          }
        None => None
      }
  }
  match cut {
    Some(c) => {
      let kept : Array[@posoco.Message] = []
      for j in 0..<sys_end {
        kept.push(messages[j])
      }
      for j in c..<n {
        kept.push(messages[j])
      }
      Ok(@posoco.CompactResult::{
        compacted_messages: kept,
        mode: @posoco.CompactMode::Replace,
      })
    }
    None => Err(TrimError::NoProgress)
  }
}

///|
/// Index of the last UserMessage at or after `start` — the maximal legal
/// cut point (keep only the system prefix and the final round).
fn last_user_cut(messages : Array[@posoco.Message], start : Int) -> Int? {
  let mut last : Int? = None
  for i in start..<messages.length() {
    if messages[i] is UserMessage(..) {
      last = Some(i)
    }
  }
  last
}
