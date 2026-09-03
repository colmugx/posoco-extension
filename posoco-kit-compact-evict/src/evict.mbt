///|
// evict.mbt — turn-protected tool-result eviction for Auto compaction.
//
// Distinct from prune (placeholder replacement under a token budget):
// eviction REMOVES whole tool-call/result pairs once they fall outside the
// protected window of the most recent user turns. The conversation skeleton
// (system, user messages, assistant text) survives verbatim; only completed
// tool work older than the window leaves the transcript. Removal is
// pair-aligned: an assistant's tool_calls are stripped together with the
// tool messages that answer them, so the result never carries a dangling
// tool_call or an orphaned result.

///|
/// Heuristic token estimate shared by the compact kits: ceil(chars / 4).
/// Cheap approximation of real tokenizers — good enough for budget
/// decisions, not for billing.
pub fn estimate_tokens(text : String) -> Int {
  (text.length() + 3) / 4
}

///|
/// Outcome of `evict_old_tool_results`: the rewritten transcript (always a
/// new array), how many tool calls (with their result messages) were
/// evicted, and the estimated tokens freed. `evicted_tool_calls == 0` means
/// nothing was removable and `messages` is a verbatim copy.
pub(all) struct EvictResult {
  messages : Array[@posoco.Message]
  evicted_tool_calls : Int
  evicted_tokens : Int
} derive(Eq)

///|
/// Start of the protected window: the index of the `turns`-th most recent
/// UserMessage counted from the end. With fewer user turns everything is
/// protected, so the function returns 0.
fn protected_turn_start(messages : Array[@posoco.Message], turns : Int) -> Int {
  let mut seen = 0
  for i = messages.length() - 1; i >= 0; i = i - 1 {
    match messages[i] {
      UserMessage(..) => {
        seen += 1
        if seen == turns {
          return i
        }
      }
      _ => ()
    }
  }
  0
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

///|
fn tool_call_tokens(call : @posoco.ToolCall) -> Int {
  estimate_tokens(call.name.to_string() + call.arguments.stringify())
}

///|
fn reasoning_tokens(reasoning : @posoco.Reasoning?) -> Int {
  match reasoning {
    Some(r) => estimate_tokens(r.content)
    None => 0
  }
}

///|
fn outcome_tokens(outcome : @posoco.ToolOutcome) -> Int {
  match outcome {
    Success(content~, ..) => estimate_tokens(content)
    ToolReportedError(content~, ..) => estimate_tokens(content)
    RuntimeFailure(message~, ..) => estimate_tokens(message)
    NotExecuted(..) => 0
  }
}

///|
/// Turn-protected tool-result eviction over a transcript.
///
/// The most recent `protect_user_turns` user turns (delimited by
/// UserMessage, current turn included) are untouchable. Older tool work is
/// evicted wholesale: an AssistantMessage with tool calls loses its
/// tool_calls — and its reasoning, which providers may then legally omit on
/// the wire — and keeps its text content, or disappears entirely when no
/// content remains; every ToolMessage answering an evicted call is removed.
/// System messages, user messages, assistants without tool calls, and tool
/// messages with no evicted caller (orphans) are kept verbatim. The input
/// array is never mutated; the result is always a fresh array.
pub fn evict_old_tool_results(
  messages : Array[@posoco.Message],
  protect_user_turns? : Int = 3,
) -> EvictResult {
  let turns = if protect_user_turns < 1 { 1 } else { protect_user_turns }
  let boundary = protected_turn_start(messages, turns)
  // Stringified call ids of evicted tool calls; membership decides which
  // older ToolMessages are dropped.
  let evicted_ids : Map[String, Unit] = Map([])
  let out : Array[@posoco.Message] = []
  let mut evicted_tool_calls = 0
  let mut evicted_tokens = 0
  for i, message in messages {
    if i >= boundary {
      out.push(message)
      continue
    }
    match message {
      AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) => {
        if tool_calls.length() == 0 {
          out.push(message)
          continue
        }
        for call in tool_calls {
          evicted_ids[call.call_id.to_string()] = ()
          evicted_tool_calls += 1
          evicted_tokens += tool_call_tokens(call)
        }
        evicted_tokens += reasoning_tokens(reasoning)
        if content.length() > 0 {
          out.push(
            @posoco.Message::AssistantMessage(
              content~,
              tool_calls=[],
              reasoning=None,
              finish_reason~,
            ),
          )
        }
      }
      ToolMessage(call_id~, outcome~, ..) =>
        if evicted_ids.contains(call_id.to_string()) {
          evicted_tokens += outcome_tokens(outcome)
        } else {
          out.push(message)
        }
      SystemMessage(..) | UserMessage(..) => out.push(message)
    }
  }
  EvictResult::{ messages: out, evicted_tool_calls, evicted_tokens, }
}

///|
/// Estimated tokens of a whole message — the eviction counterpart of the
/// summary kit's per-message estimate, for adapters projecting post-evict
/// occupancy.
fn estimate_message_tokens(message : @posoco.Message) -> Int {
  match message {
    SystemMessage(content~) => content_tokens(content)
    UserMessage(content~) => content_tokens(content)
    AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
      let mut total = content_tokens(content)
      for call in tool_calls {
        total += tool_call_tokens(call)
      }
      total + reasoning_tokens(reasoning)
    }
    ToolMessage(outcome~, ..) => outcome_tokens(outcome)
  }
}

///|
/// Estimated tokens of a whole transcript.
pub fn estimate_transcript_tokens(messages : Array[@posoco.Message]) -> Int {
  let mut total = 0
  for message in messages {
    total += estimate_message_tokens(message)
  }
  total
}
