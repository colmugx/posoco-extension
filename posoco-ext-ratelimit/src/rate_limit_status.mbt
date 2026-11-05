///|
/// Status presentation adapter. The rate-limit domain/runtime only emits a
/// RecoveryStatus projection; this adapter owns segment naming/formatting and
/// publishes the typed `@kit_events.StatusChanged` ops on the session's
/// `@posoco.Events` capability.
///
/// The capability arrives through `CompositionView::events()` in `on_compose`
/// (the manifest declares `Capability::Events`), so the owner namespace is the
/// extension id and no publisher string is repeated here. A guard that was
/// never composed (or a host that did not grant the capability) has nowhere to
/// publish and stays silent — a missing bar is a rendering gap, never an error.
priv struct RecoveryStatusSink {
  mut events : @posoco.Events?
  mut announced_segment : String?
  mut announced_value : String?
}

///|
fn RecoveryStatusSink::RecoveryStatusSink() -> RecoveryStatusSink {
  { events: None, announced_segment: None, announced_value: None, }
}

///|
/// Bind the owner-bound capability minted by the host.
fn RecoveryStatusSink::bind(
  self : RecoveryStatusSink,
  events : @posoco.Events?,
) -> Unit {
  self.events = events
}

///|
/// Whether this sink has a channel at all.
fn RecoveryStatusSink::is_bound(self : RecoveryStatusSink) -> Bool {
  self.events is Some(_)
}

///|
fn reset_segment(window_label : String?) -> String {
  match window_label {
    Some(label) => "🕐 \{label} reset"
    None => "🕐 reset"
  }
}

///|
fn civil_from_days(z : Int64) -> (Int64, Int32, Int32) {
  let z = z + 719468L
  let era = if z >= 0L { z / 146097L } else { (z - 146096L) / 146097L }
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  let year = if m <= 2L { y + 1L } else { y }
  (year, m.to_int(), d.to_int())
}

///|
fn pad2(value : Int64) -> String {
  if value < 10L {
    "0\{value}"
  } else {
    "\{value}"
  }
}

///|
fn fmt_reset_at(reset_at_ms : Int64) -> String {
  let total_s = reset_at_ms / 1000L
  let days = total_s / 86400L
  let rem = total_s - days * 86400L
  let (year, month, day) = civil_from_days(days)
  "\{year}-\{pad2(month.to_int64())}-\{pad2(day.to_int64())}T\{pad2(rem / 3600L)}:\{pad2(rem % 3600L / 60L)}:\{pad2(rem % 60L)}Z"
}

///|
/// Publish one status op on the bound capability. A closed system (the host is
/// shutting down) drops the op: publication is never an error path.
fn RecoveryStatusSink::emit(
  self : RecoveryStatusSink,
  op : @kit_events.StatusOp,
) -> Unit {
  match self.events {
    Some(events) => ignore(events.publish(@kit_events.StatusChanged(op)))
    None => ()
  }
}

///|
fn RecoveryStatusSink::publish(
  self : RecoveryStatusSink,
  status : RecoveryStatus?,
) -> Unit {
  if !self.is_bound() {
    return
  }
  let next : (String, String)? = match status {
    Some(status) =>
      Some(
        (
          reset_segment(status.window_label),
          fmt_reset_at(status.earliest_resume_at),
        ),
      )
    None => None
  }

  match (self.announced_segment, self.announced_value, next) {
    (Some(previous), _, Some((segment, _))) if previous != segment =>
      self.emit(@kit_events.Unregister(segment=previous))
    (Some(previous), _, None) =>
      self.emit(@kit_events.Unregister(segment=previous))
    _ => ()
  }

  match next {
    Some((segment, value)) => {
      let unchanged = self.announced_segment == Some(segment) &&
        self.announced_value == Some(value)
      if !unchanged {
        self.emit(
          @kit_events.Register(
            segment~,
            label=None,
            priority=90,
            value=Some(value),
            color=Some("warning"),
          ),
        )
      }
      self.announced_segment = Some(segment)
      self.announced_value = Some(value)
    }
    None => {
      self.announced_segment = None
      self.announced_value = None
    }
  }
}
