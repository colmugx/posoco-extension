///|
/// How a subagent run ended (design §2.1 failure semantics): the terminal
/// classification is always explicit in the tool result, never silent.
pub(all) enum TerminalState {
  Completed
  /// The child reported a business-level failure.
  Failed(reason~ : String)
  /// The run exceeded its timeout.
  TimedOut
  /// The run was cancelled (wave cancel / host abort).
  Cancelled
} derive(Eq, @debug.Debug)

///|
pub extend TerminalState with Eq::{not_equal, equal}

///|
pub extend TerminalState with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Map a child run's terminal state to the `agent` tool result (design §2.1):
/// `Completed` yields `Success`; every other state yields
/// `ToolReportedError` whose text opens with a model-readable terminal
/// classification (`failed: <reason>` / `timed out` / `cancelled`) so the
/// calling model can decide to retry, report, or move on. Both branches
/// append the `child_session` / usage footer, and `kind` is attributed in the
/// structured payload.
pub fn terminal_outcome(
  state~ : TerminalState,
  kind~ : String,
  child_session~ : String,
  result_text~ : String,
  turns~ : Int,
  input_tokens~ : Int,
  output_tokens~ : Int,
) -> @posoco.ToolOutcome {
  let footer = "child_session: \{child_session}\nusage: turns=\{turns} in=\{input_tokens} out=\{output_tokens}"
  match state {
    Completed => {
      let structured : Json = {
        "child_session": Json::string(child_session),
        "turns": Json::number(turns.to_double()),
        "input_tokens": Json::number(input_tokens.to_double()),
        "output_tokens": Json::number(output_tokens.to_double()),
        "state": Json::string("completed"),
        "kind": Json::string(kind),
      }
      @posoco.ToolOutcome::Success(
        content=result_text + "\n" + footer,
        structured=Some(structured),
      )
    }
    Failed(reason~) => {
      let structured : Json = {
        "state": Json::string("failed"),
        "kind": Json::string(kind),
        "child_session": Json::string(child_session),
        "reason": Json::string(reason),
      }
      @posoco.ToolOutcome::ToolReportedError(
        content="failed: \{reason}\n" + footer,
        structured=Some(structured),
      )
    }
    TimedOut => {
      let structured : Json = {
        "state": Json::string("timed_out"),
        "kind": Json::string(kind),
        "child_session": Json::string(child_session),
      }
      @posoco.ToolOutcome::ToolReportedError(
        content="timed out\n" + footer,
        structured=Some(structured),
      )
    }
    Cancelled => {
      let structured : Json = {
        "state": Json::string("cancelled"),
        "kind": Json::string(kind),
        "child_session": Json::string(child_session),
      }
      @posoco.ToolOutcome::ToolReportedError(
        content="cancelled\n" + footer,
        structured=Some(structured),
      )
    }
  }
}
