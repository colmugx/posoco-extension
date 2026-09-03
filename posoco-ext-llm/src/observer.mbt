///|
/// observer.mbt — status publication through the devkit status protocol.
///
/// The router owns three status-bar segments: `model` (priority 20, active
/// model id and effort), `tok` (priority 30, per-turn token totals), and
/// `cache` (priority 40, last round's cache hit percentage). With
/// `bus = None` every publication is a silent no-op.

///|
/// Publish the `model` segment: the active slot's model id plus the selected
/// effort, falling back to the slot's declared default effort and then
/// `"default"`.
fn RouterModelPort::publish_model_status(self : RouterModelPort) -> Unit {
  let effort = match self.active_effort {
    Some(value) => value
    None =>
      match self.active_slot().default_effort {
        Some(value) => value
        None => "default"
      }
  }
  match self.bus {
    Some(bus) =>
      @devkit.publish_status_register(
        bus,
        source="posoco_ext_llm",
        segment="model",
        priority=20,
        value="\{self.current_model_id()}:\{effort}",
      )
    None => ()
  }
}

///|
/// Publish the `tok` segment: the per-turn input/output totals.
fn RouterModelPort::publish_tok_status(self : RouterModelPort) -> Unit {
  match self.bus {
    Some(bus) =>
      @devkit.publish_status_register(
        bus,
        source="posoco_ext_llm",
        segment="tok",
        priority=30,
        value="\{self.tokens_in}↑ \{self.tokens_out}↓",
      )
    None => ()
  }
}

///|
/// Publish or hide the `cache` segment for the round that just committed:
/// register the cached/input percentage when both are reported with a
/// positive input, otherwise unregister so a stale percentage never lingers.
fn RouterModelPort::publish_cache_status(
  self : RouterModelPort,
  usage : @posoco.Usage?,
) -> Unit {
  match self.bus {
    Some(bus) => {
      let percent = match usage {
        Some(
          { cached_input_tokens: Some(cached), input_tokens: Some(input), .. }
        ) if input > 0 => Some(cached * 100 / input)
        _ => None
      }
      match percent {
        Some(value) =>
          @devkit.publish_status_register(
            bus,
            source="posoco_ext_llm",
            segment="cache",
            priority=40,
            value="\{value}%",
          )
        None =>
          @devkit.publish_status_unregister(
            bus,
            source="posoco_ext_llm",
            segment="cache",
          )
      }
    }
    None => ()
  }
}

///|
pub impl @posoco.Observer for RouterModelPort with fn on_event(
  self : RouterModelPort,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    TurnStarted => {
      self.tokens_in = 0
      self.tokens_out = 0
      self.publish_tok_status()
    }
    ModelResponseReceived(usage~, ..) => {
      match usage {
        Some(u) => {
          match u.input_tokens {
            Some(count) => self.tokens_in += count
            None => ()
          }
          match u.output_tokens {
            Some(count) => self.tokens_out += count
            None => ()
          }
        }
        None => ()
      }
      self.publish_tok_status()
      self.publish_cache_status(usage)
      self.publish_model_status()
    }
    _ => ()
  }
}

///|
pub extend RouterModelPort with @posoco.Observer::{on_event}
