///|
/// Status presentation adapter. The rate-limit domain/runtime only emits a
/// RecoveryStatus projection; this adapter owns EventBus naming/formatting.
priv struct DevkitStatusSink {
  bus : @devkit.EventBus?
  mut announced_segment : String?
  mut announced_value : String?
}

///|
fn DevkitStatusSink::DevkitStatusSink(
  bus : @devkit.EventBus?,
) -> DevkitStatusSink {
  { bus, announced_segment: None, announced_value: None, }
}

///|
fn reset_segment(window_label : String?) -> String {
  match window_label {
    Some(label) => "🕐 \{label} reset"
    None => "🕐 reset"
  }
}

///|
fn civil_from_days(z : Int64) -> (Int64, Int, Int) {
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
fn DevkitStatusSink::publish(
  self : DevkitStatusSink,
  status : RecoveryStatus?,
) -> Unit {
  let bus = match self.bus {
    Some(bus) => bus
    None => return
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
      @devkit.publish_status_unregister(
        bus,
        source="posoco_ext_ratelimit",
        segment=previous,
      )
    (Some(previous), _, None) =>
      @devkit.publish_status_unregister(
        bus,
        source="posoco_ext_ratelimit",
        segment=previous,
      )
    _ => ()
  }

  match next {
    Some((segment, value)) => {
      let unchanged = self.announced_segment == Some(segment) &&
        self.announced_value == Some(value)
      if !unchanged {
        @devkit.publish_status_register(
          bus,
          source="posoco_ext_ratelimit",
          segment~,
          priority=90,
          value~,
          color="warning",
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
