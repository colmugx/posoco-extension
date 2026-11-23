///|
/// Presentation-neutral snapshot. The actor never leaks its mutable entries.
pub(all) struct LoopJob {
  id : String
  session_id : String
  prompt : String
  interval_ms : Int64
  next_due_at_ms : Int64
  status : String
  run_count : Int32
  failure_count : Int32
}

///|
priv struct LoopEntry {
  id : String
  session_id : String
  prompt : String
  interval_ms : Int64
  mut next_due_at_ms : Int64
  mut status : String
  mut generation : Int32
  mut run_count : Int32
  mut failure_count : Int32
  mut busy_count : Int32
}

///|
fn LoopEntry::snapshot(self : LoopEntry) -> LoopJob {
  {
    id: self.id,
    session_id: self.session_id,
    prompt: self.prompt,
    interval_ms: self.interval_ms,
    next_due_at_ms: self.next_due_at_ms,
    status: self.status,
    run_count: self.run_count,
    failure_count: self.failure_count,
  }
}

///|
priv enum LoopAction {
  ListJobs
  CreateJob(interval_ms~ : Int64, prompt~ : String)
  PauseJob(id~ : String)
  ResumeJob(id~ : String)
  StopJob(id~ : String)
}

///|
/// Split exactly at the first ASCII whitespace. The rest remains untouched
/// except for leading/trailing whitespace; task text is never shell-evaluated.
fn loop_split_first(raw : String) -> (String, String) {
  let text = raw.trim()
  let mut at = 0
  while at < text.length() {
    let ch = text[at]
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      break
    }
    at += 1
  }
  let head = text[:at].to_owned()
  let tail = if at < text.length() {
    text[at:].trim().to_owned()
  } else {
    ""
  }
  (head, tail)
}

///|
/// Accept explicit, bounded intervals: 1s..24h, with s/m/h/d suffixes.
/// The upper bound avoids timer overflow and accidental runaway scheduling.
pub fn parse_loop_interval(token : String) -> Result[Int64, String] {
  let value = token.trim()
  if value.length() < 2 {
    return Err("expected interval such as 30s, 5m or 1h")
  }
  let suffix = value[value.length() - 1]
  let multiplier : Int64 = match suffix {
    's' => 1000L
    'm' => 60000L
    'h' => 3600000L
    'd' => 86400000L
    _ => return Err("unsupported interval unit (use s, m, h or d)")
  }
  let digits = value[:value.length() - 1].to_owned()
  for ch in digits {
    if ch < '0' || ch > '9' {
      return Err("interval must be a positive integer with a unit")
    }
  }
  let number = @string.parse_int64(digits) catch {
    _ => return Err("interval is out of range")
  }
  if number <= 0L || number > 86400000L / multiplier {
    return Err("interval must be between 1s and 24h")
  }
  Ok(number * multiplier)
}

///|
fn parse_loop_action(raw : String) -> Result[LoopAction, String] {
  let (verb, tail) = loop_split_first(raw)
  match verb {
    "" | "list" if tail == "" => Ok(ListJobs)
    "stop" if tail != "" => {
      let (id, extra) = loop_split_first(tail)
      if extra != "" { Err("usage: /loop stop <id>") } else { Ok(StopJob(id~)) }
    }
    "pause" if tail != "" => {
      let (id, extra) = loop_split_first(tail)
      if extra != "" { Err("usage: /loop pause <id>") } else { Ok(PauseJob(id~)) }
    }
    "resume" if tail != "" => {
      let (id, extra) = loop_split_first(tail)
      if extra != "" { Err("usage: /loop resume <id>") } else { Ok(ResumeJob(id~)) }
    }
    "stop" | "pause" | "resume" => Err("missing loop id")
    "list" => Err("usage: /loop list")
    _ => {
      if tail == "" {
        return Err("usage: /loop <interval> <task> (example: /loop 5m check CI)")
      }
      match parse_loop_interval(verb) {
        Ok(interval_ms) => Ok(CreateJob(interval_ms~, prompt=tail))
        Err(reason) => Err(reason)
      }
    }
  }
}
