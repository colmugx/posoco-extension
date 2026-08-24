///|
/// Observer view: self-collect turn counters, session-cumulative tool-call
/// counts, per-turn token usage, per-round cache facts, and per-round
/// token-efficiency timings from agent-level turn events. Session redirects
/// also refresh the session segment. Every DISPLAYED state change
/// re-renders exactly once; timing-only probes (first-token anchors) update
/// state without rendering.
pub impl @posoco.Observer for StatusBar with fn on_event(
  self : StatusBar,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    TurnStarted => {
      self.state.turn_count += 1
      // tool_calls is session-cumulative: not reset here (see StatusBarState).
      self.state.tokens_in = 0
      self.state.tokens_out = 0
      self.state.latency_ms = None
      let now = (self.clock)()
      self.state.turn_started_ms = Some(now)
      self.state.round_started_ms = Some(now)
      self.state.first_token_ms = None
      self.render()
    }
    ToolCallPending(_) => {
      self.state.tool_calls += 1
      self.render()
    }
    StreamChunkReceived(chunk~) =>
      // First streamed token of the round anchors TTFT. No display change:
      // the segment materializes when the round commits.
      match chunk {
        TextDelta(token~) | ReasoningDelta(token~) => {
          ignore(token)
          match (self.state.round_started_ms, self.state.first_token_ms) {
            (Some(_), None) => self.state.first_token_ms = Some((self.clock)())
            _ => ()
          }
        }
        ToolCallDelta(..) | Usage(..) | Finish(..) => ()
      }
    ModelResponseReceived(usage~, ..) => {
      let now = (self.clock)()
      // Summarize the round that just committed, then re-anchor for the
      // next one (a tool loop runs one model round per ToolCallPending
      // batch, so "each round" = each ModelResponseReceived).
      match self.state.round_started_ms {
        Some(started) => {
          match self.state.first_token_ms {
            Some(first) => self.state.ttft_ms = Some((first - started).to_int())
            None => ()
          }
          let span = now - started
          if span >= 0 && span <= 0x7fffffff {
            let span_int = span.to_int()
            self.state.round_gen_ms = Some(span_int)
            match usage {
              Some({ output_tokens: Some(out), .. }) =>
                if span_int > 0 {
                  let tps = out.to_double() * 1000.0 / span_int.to_double()
                  self.state.round_tps = Some(tps)
                  self.state.sum_tps = self.state.sum_tps + tps
                  self.state.tps_rounds += 1
                }
              _ => ()
            }
          }
        }
        None => ()
      }
      self.state.round_started_ms = Some(now)
      self.state.first_token_ms = None
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
          self.state.round_input = usage.input_tokens
          self.state.round_cached = usage.cached_input_tokens
        }
        None => ()
      }
      self.render()
    }
    TurnCompleted | TurnFailed(_) => {
      // Turn latency from the injected clock — hosts that prefer their own
      // measurement still win: set_latency is a later write.
      match (self.state.turn_started_ms, self.state.latency_ms) {
        (Some(started), None) => {
          let elapsed = (self.clock)() - started
          if elapsed >= 0 && elapsed <= 0x7fffffff {
            self.state.latency_ms = Some(elapsed.to_int())
          }
        }
        _ => ()
      }
      self.render()
    }
    SessionRedirect(to~, ..) => {
      self.state.session_id = Some(to)
      self.render()
    }
    _ => ()
  }
}
