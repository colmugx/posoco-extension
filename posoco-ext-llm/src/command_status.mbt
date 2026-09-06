///|
/// `/status` command: a read-only report of the active provider's facts —
/// model, context window, reasoning efforts, and any quota readings the
/// provider has published on the shared bus or registered in the devkit
/// quota registry (bus windows win over registry duplicates).

///|
/// `/status` accepts no arguments. Tolerate the "nothing after the slash"
/// spellings hosts produce (`null`, empty string, empty object, empty
/// `_positional`); anything else is a caller bug worth raising on.
fn expect_no_args(args : Json) -> Unit raise @posoco.CommandError {
  let empty = match args {
    Json::Null => true
    Json::String(raw) => raw.trim().to_owned().length() == 0
    Json::Object(fields) => {
      let mut empty = true
      for key, value in fields {
        let meaningful = match (key, value) {
          ("_positional", Json::String(raw)) =>
            raw.trim().to_owned().length() > 0
          _ => true
        }
        if meaningful {
          empty = false
        }
      }
      empty
    }
    _ => false
  }
  if !empty {
    raise @posoco.CommandError::InvalidArgs(reason="/status takes no arguments")
  }
}

///|
/// Provider-stated percentages render without trailing `.0` noise.
fn format_status_percent(value : Double) -> String {
  if value >= 0.0 && value == value.floor() && value < 1000000000.0 {
    value.to_int().to_string()
  } else {
    value.to_string()
  }
}

///|
/// Build the `/status` feedback text and structured payload from the active
/// slot plus the bus-cached quota segments ("5h", "weekly") and optional
/// pull-style registry readings. Bus windows win: registry readings only
/// fill windows the bus has not published, and a reading that states
/// nothing is skipped rather than estimated. Package-visible: the
/// CommandPort impl in command_model.mbt wraps it into a CommandOutcome.
fn RouterModelPort::status_report(
  self : RouterModelPort,
  readings? : Array[@devkit.QuotaReading] = [],
) -> (String, Json) {
  let slot = self.active_slot()
  let effort = match self.active_effort() {
    Some(value) => value
    None =>
      match slot.default_effort {
        Some(value) => value
        None => "default"
      }
  }
  let context = match slot.context_window {
    Some(n) => "\{n} tokens"
    None => "unknown"
  }
  let efforts = if slot.thinking_efforts.is_empty() {
    "n/a"
  } else {
    slot.thinking_efforts.join(",")
  }
  let quota : Array[(String, String)] = []
  let shown : Array[String] = []
  for window in ["5h", "weekly"] {
    match self.status_segments.get(window) {
      Some(value) => {
        quota.push((window, value))
        shown.push(window)
      }
      None => ()
    }
  }
  for reading in readings {
    if reading.window == "balance" {
      if !shown.contains("balance") {
        match (reading.amount, reading.available) {
          (Some((value, currency)), _) => {
            quota.push(("balance", "\{value} \{currency}"))
            shown.push("balance")
          }
          (None, Some(false)) => {
            quota.push(("balance", "unavailable"))
            shown.push("balance")
          }
          _ => ()
        }
      }
    } else if reading.used_percent is Some(percent) {
      if !shown.contains(reading.window) {
        // Providers declare used; the display follows the codex CLI remaining
        // convention. 100 − used is exact arithmetic on the declared value,
        // not an estimate.
        let left = 100.0 - percent
        quota.push((reading.window, format_status_percent(left) + "% left"))
        shown.push(reading.window)
      }
    }
  }
  let lines : Array[String] = [
    "provider: \{self.current_provider_id()}",
    "model: \{self.current_model_id()}",
    "effort: \{effort}",
    "context window: \{context}",
    "reasoning efforts: \{efforts}",
  ]
  if quota.is_empty() {
    lines.push("quota: no readings yet")
  } else {
    for entry in quota {
      if entry.0 == "balance" {
        lines.push("balance: \{entry.1}")
      } else {
        // Bus window values arrive already shaped as "N% left" from their
        // publisher; pass them through unchanged.
        lines.push("\{entry.0}: \{entry.1}")
      }
    }
  }
  let quota_fields : Array[(String, Json)] = []
  for entry in quota {
    quota_fields.push((entry.0, Json::string(entry.1)))
  }
  let effort_values : Array[Json] = []
  for value in slot.thinking_efforts {
    effort_values.push(Json::string(value))
  }
  let structured = Json::object(
    Map::from_array([
      ("provider", Json::string(self.current_provider_id())),
      ("model", Json::string(self.current_model_id())),
      ("effort", Json::string(effort)),
      (
        "context_window",
        match slot.context_window {
          Some(n) => Json::number(n.to_double())
          None => Json::null()
        },
      ),
      ("reasoning_efforts", Json::array(effort_values)),
      (
        "quota",
        if quota.is_empty() {
          Json::null()
        } else {
          Json::object(Map::from_array(quota_fields))
        },
      ),
    ]),
  )
  (lines.join("\n"), structured)
}
