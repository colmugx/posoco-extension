///|
/// Observer view: self-collect turn counters, tool-call counts, and token
/// usage from agent-level turn events. Session redirects also refresh the
/// session segment. Every state change re-renders exactly once.
pub impl @posoco.Observer for StatusBar with fn on_event(
  self : StatusBar,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    TurnStarted => {
      self.state.turn_count += 1
      self.state.tools_this_turn = 0
      self.state.tokens_in = 0
      self.state.tokens_out = 0
      self.state.latency_ms = None
      self.render()
    }
    ToolCallPending(_) => {
      self.state.tools_this_turn += 1
      self.render()
    }
    ModelResponseReceived(usage~, ..) => {
      match usage {
        Some(usage) => {
          match usage.input_tokens {
            Some(n) => self.state.tokens_in += n
            None => ()
          }
          match usage.output_tokens {
            Some(n) => self.state.tokens_out += n
            None => ()
          }
        }
        None => ()
      }
      self.render()
    }
    TurnCompleted | TurnFailed(_) => self.render()
    SessionRedirect(to~, ..) => {
      self.state.session_id = Some(to)
      self.render()
    }
    _ => ()
  }
}
