///|
/// Convergence guidance for a tool-call loop.
///
/// The instruction is appended as one request-local user message at the very end of
/// the outgoing request — never spliced into the middle. Appending keeps the
/// conversation prefix byte-identical, so the server's cached KV prefix is
/// still reusable for this turn; rewriting history would invalidate it.

///|
/// Detect a tool-call cycle only within the current user turn. Tool results
/// do not reset the streak; any different assistant action does. A
/// conservative threshold of three identical calls avoids intervening on
/// ordinary retries.
pub fn repeated_tool_calls(messages : Array[@posoco.Message]) -> Bool {
  let mut previous = ""
  let mut previous_result : @posoco.ToolOutcome? = None
  let mut streak = 0
  for i = messages.length() - 1; i >= 0; i = i - 1 {
    match messages[i] {
      @posoco.Message::UserMessage(..) => break
      @posoco.Message::AssistantMessage(tool_calls~, ..) => {
        if tool_calls.length() != 1 {
          break
        }
        let call = tool_calls[0]
        let fingerprint = call.name.to_string() +
          "\n" +
          call.arguments.stringify()
        if previous == "" || previous == fingerprint {
          previous = fingerprint
          streak += 1
          if streak >= 3 {
            return true
          }
        } else {
          break
        }
      }
      @posoco.Message::ToolMessage(outcome~, ..) =>
        match previous_result {
          Some(last) => if last != outcome { break }
          None => previous_result = Some(outcome)
        }
      @posoco.Message::SystemMessage(..) => ()
    }
  }
  false
}

///|
/// Deliberately does not claim the last tool result succeeded or forbid
/// necessary retries. Ask for an evidence-based decision and an alternative.
pub fn convergence_instruction() -> String {
  "The same tool call has been repeated at least three times in the current user turn. Before calling it again, evaluate the latest tool result and whether the arguments would produce new evidence. If not, stop repeating it: choose a different action or provide the best supported partial answer with the remaining uncertainty. Do not invent successful tool results."
}
