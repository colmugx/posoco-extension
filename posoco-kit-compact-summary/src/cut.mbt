///|
/// Where to split the transcript for a summary-Replace compaction.
///
/// The range to summarize is `[protect_prefix, head_end)`; the range kept
/// verbatim is `[kept_from, messages.length())`. `head_end == kept_from`:
/// they are the same boundary, carried as two fields because the progressive
/// stage may give the oversized-turn prefix its own summary (split turn).
///
/// `is_split_turn` reports that the turn containing the cut is itself larger
/// than the keep-recent budget; `turn_start_index` points at that turn's
/// UserMessage (or the turn head when no UserMessage precedes the cut).
///
/// Summary messages (recognized by `is_summary_message`) are not special-
/// cased in this stage: they count as ordinary content in both the budget
/// walk and the head range. Anchored re-summarization from the latest
/// summary is left to the progressive stage.
pub(all) struct CutPoint {
  head_end : Int
  kept_from : Int
  is_split_turn : Bool
  turn_start_index : Int
} derive(Eq, Debug)

///|
/// Choose the cut point for a summary-Replace compaction.
///
/// Walks backwards accumulating `estimate_tokens` until the keep-recent
/// budget is reached, then retreats to the nearest safe boundary at or
/// below the candidate:
///
/// - a `UserMessage`, or
/// - a turn-head `AssistantMessage` (conversation start, right after the
///   protected prefix, or directly after a UserMessage).
///
/// The boundary never falls between an AssistantMessage and its following
/// ToolMessage: a candidate on a tool result retreats to the assistant that
/// issued the call (or earlier), so an assistant+tool pair always stays on
/// one side.
///
/// Messages in `[0, protect_prefix)` are session-prefix background
/// (environment context, program-injected user messages): they are never
/// summarized and never counted against the keep-recent budget. The caller
/// keeps them verbatim in front of the result. When `kept_from ==
/// protect_prefix` the head range is empty and there is nothing to
/// summarize.
pub fn select_cut(
  messages : Array[@posoco.Message],
  keep_recent_tokens : Int,
  protect_prefix? : Int = 0,
) -> CutPoint {
  let n = messages.length()
  let prefix = if protect_prefix < 0 {
    0
  } else if protect_prefix > n {
    n
  } else {
    protect_prefix
  }
  let mut running = 0
  let mut candidate = -1
  let mut i = n - 1
  while i >= prefix {
    running += estimate_message_tokens(messages[i])
    if running >= keep_recent_tokens {
      candidate = i
      break
    }
    i -= 1
  }
  if candidate < 0 {
    // Everything above the protected prefix fits in the budget: nothing to
    // summarize.
    return CutPoint::{
      head_end: prefix,
      kept_from: prefix,
      is_split_turn: false,
      turn_start_index: prefix,
    }
  }
  let mut boundary = candidate
  while boundary > prefix && !is_safe_boundary(messages, boundary, prefix) {
    boundary -= 1
  }
  let turn_start = turn_start_of(messages, candidate, prefix)
  let turn_end = turn_end_of(messages, turn_start, n)
  let mut turn_tokens = 0
  for j in turn_start..<turn_end {
    turn_tokens += estimate_message_tokens(messages[j])
  }
  CutPoint::{
    head_end: boundary,
    kept_from: boundary,
    is_split_turn: turn_tokens > keep_recent_tokens,
    turn_start_index: turn_start,
  }
}

///|
/// A boundary may land on a UserMessage, or on an AssistantMessage that
/// heads a turn (conversation start, right after the protected prefix, or
/// directly after a UserMessage). ToolMessages and mid-turn assistant
/// messages are never boundaries.
fn is_safe_boundary(
  messages : Array[@posoco.Message],
  k : Int,
  prefix : Int,
) -> Bool {
  if k < prefix || k >= messages.length() {
    return false
  }
  match messages[k] {
    UserMessage(..) => true
    AssistantMessage(..) =>
      if k == 0 || k == prefix {
        true
      } else {
        match messages[k - 1] {
          UserMessage(..) => true
          _ => false
        }
      }
    _ => false
  }
}

///|
/// Index of the first message of the turn containing `k`: the nearest
/// UserMessage at or before `k`, clamped at the protected prefix (a turn may
/// head with an assistant when no user input precedes it).
fn turn_start_of(
  messages : Array[@posoco.Message],
  k : Int,
  prefix : Int,
) -> Int {
  match messages[k] {
    UserMessage(..) => return k
    _ => ()
  }
  let mut j = k
  while j > prefix {
    match messages[j - 1] {
      UserMessage(..) => return j - 1
      _ => j -= 1
    }
  }
  j
}

///|
/// Index one past the last message of the turn starting at `t`.
fn turn_end_of(messages : Array[@posoco.Message], t : Int, n : Int) -> Int {
  let mut j = t + 1
  while j < n {
    match messages[j] {
      UserMessage(..) => break
      _ => j += 1
    }
  }
  j
}

///|
fn estimate_message_tokens(message : @posoco.Message) -> Int {
  match message {
    SystemMessage(content~) => content_tokens(content)
    UserMessage(content~) => content_tokens(content)
    AssistantMessage(content~, tool_calls~, ..) => {
      let mut total = content_tokens(content)
      for call in tool_calls {
        total += estimate_tokens(
          call.name.to_string() + call.arguments.stringify(),
        )
      }
      total
    }
    ToolMessage(outcome~, ..) =>
      match outcome {
        Success(content~, ..) => estimate_tokens(content)
        ToolReportedError(content~, ..) => estimate_tokens(content)
        RuntimeFailure(message~, ..) => estimate_tokens(message)
        NotExecuted(..) => 0
      }
  }
}

///|
fn content_tokens(content : Array[@posoco.Content]) -> Int {
  let mut total = 0
  for block in content {
    match block {
      Text(text) => total += estimate_tokens(text)
      Image(..) => total += 1
    }
  }
  total
}
