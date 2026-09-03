///|
/// Heuristic token estimate shared by the compact kits: ceil(chars / 4).
/// This is a cheap approximation of real tokenizers — good enough for
/// budget decisions, not for billing.
pub fn estimate_tokens(text : String) -> Int {
  (text.length() + 3) / 4
}

///|
/// Whether `prune_tool_outputs` changed the transcript.
pub(all) enum PruneAction {
  Pruned
  Noop
} derive(Eq)

///|
/// Outcome of `prune_tool_outputs`: the rewritten transcript (always a new
/// array), the estimated tokens freed, and how many tool outputs were
/// cleared. On `Noop` both counts are zero.
pub(all) struct PruneResult {
  messages : Array[@posoco.Message]
  pruned_tokens : Int
  pruned_count : Int
  action : PruneAction
} derive(Eq)

///|
/// Shallow copy of a message array (elements are immutable and shared).
fn copy_messages(messages : Array[@posoco.Message]) -> Array[@posoco.Message] {
  let out : Array[@posoco.Message] = []
  for message in messages {
    out.push(message)
  }
  out
}

///|
/// Start of the protected window: the index of the second-to-last user
/// message from the end. With fewer than two user turns everything is
/// protected, so the function returns 0.
fn recent_two_turn_start(messages : Array[@posoco.Message]) -> Int {
  let mut seen = 0
  for i = messages.length() - 1; i >= 0; i = i - 1 {
    match messages[i] {
      @posoco.Message::UserMessage(..) => {
        seen += 1
        if seen == 2 {
          return i
        }
      }
      _ => ()
    }
  }
  0
}

///|
/// Tool name and output content of a completed (`Success`) tool message,
/// or None for any other message or outcome.
fn completed_tool_output(message : @posoco.Message) -> (String, String)? {
  match message {
    ToolMessage(tool_name~, outcome~, ..) =>
      match outcome {
        Success(content~, ..) => Some((tool_name.to_string(), content))
        _ => None
      }
    _ => None
  }
}

///|
/// OpenCode-style tool output micro-compaction over a transcript.
///
/// Scans completed tool outputs (`ToolMessage` with `Success`) from newest
/// to oldest. The two most recent user turns and every tool named in
/// `protected_tools` are untouchable and do not spend the budget. Every
/// eligible output unconditionally adds its estimate to a running total;
/// once the total exceeds `protect_tokens`, that output and every older
/// eligible output become prunable: their content is replaced wholesale by
/// `placeholder` in a freshly built `ToolMessage` that keeps the original
/// call id and tool name. Nothing is cleared unless the reclaimable total
/// exceeds `min_gain`, in which case the transcript is returned unchanged
/// (as a copy) with `action=Noop`. Non-tool messages and failed /
/// not-executed outcomes are never touched, and the input array is never
/// mutated.
pub fn prune_tool_outputs(
  messages : Array[@posoco.Message],
  protect_tokens? : Int = 40000,
  min_gain? : Int = 20000,
  placeholder? : String = "[Old tool result content cleared]",
  protected_tools? : Array[String] = [],
) -> PruneResult {
  let protected_from = recent_two_turn_start(messages)
  let mut spent = 0
  // Prunable (index, original estimate) pairs, newest first.
  let prunable : Array[(Int, Int)] = []
  for i = messages.length() - 1; i >= 0; i = i - 1 {
    if i < protected_from {
      match completed_tool_output(messages[i]) {
        Some((name, content)) =>
          if !protected_tools.contains(name) {
            let tokens = estimate_tokens(content)
            spent += tokens
            if spent > protect_tokens {
              prunable.push((i, tokens))
            }
          }
        None => ()
      }
    }
  }
  let gain = prunable.fold(init=0, fn(total, entry) { total + entry.1 })
  if gain <= min_gain {
    PruneResult::{
      messages: copy_messages(messages),
      pruned_tokens: 0,
      pruned_count: 0,
      action: Noop,
    }
  } else {
    let targets : Map[Int, Int] = Map::from_array(prunable)
    let out : Array[@posoco.Message] = []
    let mut cleared_tokens = 0
    let mut cleared_count = 0
    for i, message in messages {
      match targets.get(i) {
        Some(tokens) =>
          match message {
            ToolMessage(call_id~, tool_name~, ..) => {
              out.push(
                @posoco.Message::ToolMessage(
                  call_id~,
                  tool_name~,
                  outcome=@posoco.ToolOutcome::Success(
                    content=placeholder,
                    structured=None,
                  ),
                ),
              )
              cleared_tokens += tokens
              cleared_count += 1
            }
            _ => out.push(message)
          }
        None => out.push(message)
      }
    }
    PruneResult::{
      messages: out,
      pruned_tokens: cleared_tokens,
      pruned_count: cleared_count,
      action: Pruned,
    }
  }
}
