///|
/// Child observer that turns one run's TurnEvents into a bounded activity log.
/// The child cannot mutate the Board; this observer only reads its own events.
pub(all) struct TicketActivityObserver {
  run : WorkRun
}

///|
pub impl @posoco.Observer for TicketActivityObserver with fn on_event(
  self : TicketActivityObserver,
  _scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  let run = self.run
  match event {
    TurnStarted => {
      run.steps = run.steps + 1
      run.activity("step", "Step \{run.steps} started")
    }
    ModelRequestStarted => run.activity("model", "Waiting for the model")
    ModelResponseReceived(usage~, ..) => {
      let detail = match usage {
        Some(usage) =>
          "Model responded (in \{usage.input_tokens.unwrap_or(0)}, out \{usage.output_tokens.unwrap_or(0)})"
        None => "Model responded"
      }
      run.activity("model", detail)
    }
    ToolCallPending(call) =>
      run.activity(
        "tool",
        "Tool · \{call.name.to_string()} · approval needed",
      )
    ToolCallApproved(call~, ..) =>
      run.activity("tool", "Tool · \{call.name.to_string()} · approved")
    ToolCallStarted(call~) => {
      run.current_tool = Some(call.name.to_string())
      let preview = one_line_preview(call.arguments.stringify(), 120)
      let detail = if preview == "" {
        "Tool · \{call.name.to_string()} · running"
      } else {
        "Tool · \{call.name.to_string()} · \{preview}"
      }
      run.activity("tool", detail)
    }
    ToolCallSucceeded(call~, content~, ..) => {
      run.current_tool = None
      let preview = one_line_preview(content, 120)
      let detail = if preview == "" {
        "Tool · \{call.name.to_string()} · done"
      } else {
        "Tool · \{call.name.to_string()} · done · \{preview}"
      }
      run.activity("tool", detail)
    }
    ToolCallFailed(call~, failure~) => {
      run.current_tool = None
      run.activity(
        "error",
        "Tool · \{call.name.to_string()} · failed · \{failure.summary()}",
      )
    }
    ToolCallRejected(call~, reason~) => {
      run.current_tool = None
      run.activity(
        "error",
        "Tool · \{call.name.to_string()} · rejected · \{reason}",
      )
    }
    ToolCallAbandoned(call~, reason~) => {
      run.current_tool = None
      run.activity(
        "error",
        "Tool · \{call.name.to_string()} · abandoned · \{reason}",
      )
    }
    TurnCompleted => run.activity("step", "Step completed")
    TurnFailed(message) => run.activity("error", "Step failed · \{message}")
    StreamChunkReceived(chunk~) =>
      match chunk {
        TextDelta(token~) =>
          run.preview = append_tail(run.preview, token, 600)
        ReasoningDelta(token~) =>
          run.reasoning = append_tail(run.reasoning, token, 600)
        _ => ()
      }
    UserRequestStarted(prompt~, ..) =>
      run.activity(
        "question",
        "Waiting for your answer · \{one_line_preview(prompt, 100)}",
      )
    UserRequestFinished(outcome~, ..) =>
      run.activity("question", "Answer received · \{outcome}")
    _ => ()
  }
}



///|
pub extend TicketActivityObserver with @posoco.Observer::{on_event}
