///|
/// Registry-driven quota segments on the status bar.
///
/// The router pulls the active provider's registered `QuotaSource` from the
/// devkit quota registry and publishes the readings as status segments:
/// balance readings render a `balance` segment with `"<value> <currency>"`,
/// window readings render the window name with `"<n>% left"` (codex CLI
/// remaining convention). DeepSeek's balance and the coding-plan windows
/// (zai/kimi) ride this generic path; codex has no registry source, so the
/// router clears its own quota segments for it and the bar stays owned by
/// `CodexQuotaStatus` (distinct source; provider scoping keeps them mutually
/// exclusive). With `bus = None` every publication is a silent no-op, and no
/// failure here ever escapes: refresh runs after the chat response and
/// captures every error into a backoff.

///|
/// A successful registry pull throttles re-reads for 30 minutes.
let quota_refresh_interval_ms : Int64 = 1800000L

///|
/// A failed registry pull backs off for 5 minutes so a bad endpoint never
/// slows chat.
let quota_failure_backoff_ms : Int64 = 300000L

///|
/// Bar placement of the router's quota segments (same slot as the codex
/// windows; provider scoping keeps the two publishers mutually exclusive).
let quota_segment_priority : Int = 45

///|
/// Local coloring heuristic over provider-stated numbers (color is a UI
/// decision, never a data estimate), on the remaining axis: exhausted
/// windows read as errors, windows within 20% of exhaustion as warnings.
fn quota_color_role(left_percent : Double) -> String? {
  if left_percent <= 0.0 {
    Some("error")
  } else if left_percent <= 20.0 {
    Some("warning")
  } else {
    None
  }
}

///|
/// Register one quota segment on the bus.
fn publish_quota_segment(
  bus : @devkit.EventBus,
  segment~ : String,
  value~ : String,
  color~ : String?,
) -> Unit {
  match color {
    Some(role) =>
      @devkit.publish_status_register(
        bus,
        source="posoco_ext_llm",
        segment~,
        priority=quota_segment_priority,
        value~,
        color=role,
      )
    None =>
      @devkit.publish_status_register(
        bus,
        source="posoco_ext_llm",
        segment~,
        priority=quota_segment_priority,
        value~,
      )
  }
}

///|
/// Render the cached registry readings as status segments. Segments that
/// were published before but vanished from the current readings are
/// unregistered, so a stale number never lingers on the bar.
fn RouterModelPort::publish_quota_segments(self : RouterModelPort) -> Unit {
  let bus = match self.bus {
    Some(bus) => bus
    None => return
  }
  let published : Array[String] = []
  for reading in self.quota_readings {
    if reading.window == "balance" {
      match reading.amount {
        Some((value, currency)) => {
          published.push("balance")
          publish_quota_segment(
            bus,
            segment="balance",
            value="\{value} \{currency}",
            color=None,
          )
        }
        None => ()
      }
    } else {
      match reading.used_percent {
        Some(percent) => {
          // Providers declare used; the bar follows the codex CLI remaining
          // convention. 100 − used is exact arithmetic on the declared value,
          // not an estimate.
          let left = 100.0 - percent
          published.push(reading.window)
          publish_quota_segment(
            bus,
            segment=reading.window,
            value=format_status_percent(left) + "% left",
            color=quota_color_role(left),
          )
        }
        None => ()
      }
    }
  }
  for segment in self.quota_shown {
    if !published.contains(segment) {
      @devkit.publish_status_unregister(bus, source="posoco_ext_llm", segment~)
    }
  }
  self.quota_shown = published
}

///|
/// Pull the active provider's registry source when due: a successful pull
/// throttles re-reads for 30 minutes, a failed one backs off for 5. Runs
/// after the chat response; never raises. A provider without a registry
/// source (codex, for example) clears the router's quota segments — the bar
/// facts belong to that provider's own publisher.
async fn RouterModelPort::refresh_quota_if_due(
  self : RouterModelPort,
) -> Unit noraise {
  let now = @async.now()
  if now - self.quota_fetched_at < quota_refresh_interval_ms {
    return
  }
  if now - self.quota_failed_at < quota_failure_backoff_ms {
    return
  }
  match @devkit.quota_registry_lookup(self.current_provider_id()) {
    Some(source) => {
      let result = source.read() catch { _ => Err("quota pull failed") }
      match result {
        Ok(readings) => {
          self.quota_readings = readings
          self.quota_fetched_at = now
          self.quota_failed_at = 0L
          self.publish_quota_segments()
        }
        Err(_) => self.quota_failed_at = now
      }
    }
    None => self.clear_quota_segments()
  }
}

///|
/// Force an immediate registry pull, skipping the throttle window. The
/// `/model` and `/effort` switches use this so the bar reflects the new
/// provider as soon as the command returns; failures back off like the
/// deferred path, and a provider without a source clears the segments.
async fn RouterModelPort::refresh_quota_now(
  self : RouterModelPort,
) -> Unit noraise {
  let now = @async.now()
  match @devkit.quota_registry_lookup(self.current_provider_id()) {
    Some(source) => {
      let result = source.read() catch { _ => Err("quota pull failed") }
      match result {
        Ok(readings) => {
          self.quota_readings = readings
          self.quota_fetched_at = now
          self.quota_failed_at = 0L
          self.publish_quota_segments()
        }
        Err(_) => self.quota_failed_at = now
      }
    }
    None => self.clear_quota_segments()
  }
}

///|
/// Unregister every quota segment this router published and reset the pull
/// cache, so the next active provider starts clean.
fn RouterModelPort::clear_quota_segments(self : RouterModelPort) -> Unit {
  match self.bus {
    Some(bus) =>
      for segment in self.quota_shown {
        @devkit.publish_status_unregister(
          bus,
          source="posoco_ext_llm",
          segment~,
        )
      }
    None => ()
  }
  self.quota_shown = []
  self.quota_readings = []
  self.quota_fetched_at = 0L
  self.quota_failed_at = 0L
}
