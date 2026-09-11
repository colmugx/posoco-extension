///|
// Capturable-output channel to the herdr CLI (the delegation transport).
// herdr writes result JSON on stdout and error JSON on stderr, so a backend
// must capture the two streams SEPARATELY — merged output would make a
// success read as an error. The trait below is the only seam; everything
// else in this file is pure and shared across targets.
priv trait HerdrCli {
  async fn run(self : Self, argv : Array[String]) -> (Int, String, String) raise @posoco.RuntimeError
}

///|
// One-shot headless always finishes turn 1 (cetas-headless lib/loop.mbt
// prints turn_marker(1)); `wait-output --match` takes this literal substring.
let herdr_headless_marker : String = "[cetas-headless] turn 1 done"

///|
let herdr_turn_failed_prefix : String = "[cetas-headless] turn failed: "

///|
let herdr_session_prefix : String = "session: "

///|
fn herdr_split_argv(
  bin : String,
  pane : String,
  cwd : String,
  direction : String,
) -> Array[String] {
  [
    bin, "pane", "split", "--pane", pane, "--direction", direction, "--cwd", cwd,
    "--no-focus",
  ]
}

///|
// command_line is ONE argv element: the pane's own shell parses its quoting.
fn herdr_run_argv(
  bin : String,
  new_pane : String,
  command_line : String,
) -> Array[String] {
  [bin, "pane", "run", new_pane, command_line]
}

///|
fn herdr_wait_argv(
  bin : String,
  new_pane : String,
  timeout_ms : Int,
) -> Array[String] {
  [
    bin,
    "pane",
    "wait-output",
    "--match",
    herdr_headless_marker,
    "--timeout",
    timeout_ms.to_string(),
    new_pane,
  ]
}

///|
fn herdr_read_argv(bin : String, new_pane : String) -> Array[String] {
  [bin, "pane", "read", new_pane, "--source", "recent-unwrapped"]
}

///|
fn herdr_close_argv(bin : String, pane : String) -> Array[String] {
  [bin, "pane", "close", pane]
}

///|
/// New pane id from split's stdout JSON (`result.pane.pane_id`). An error
/// envelope (`{"error":{...}}`) carries no `result`, so it lands here as
/// None, as does unparseable output.
fn parse_split_pane_id(stdout : String) -> String? {
  let json : Json = @json.parse(stdout) catch { _ => return None }
  match json {
    Object(fields) =>
      match fields.get("result") {
        Some(Object(result)) =>
          match result.get("pane") {
            Some(Object(pane)) =>
              match pane.get("pane_id") {
                Some(String(id)) => Some(id)
                _ => None
              }
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Shell command line for `pane run`: the headless binary, permission flags
/// (readonly default, `--yolo` for write), optional model/effort/session,
/// then `--` and the single-quoted task.
fn headless_command_line(
  headless_bin : String,
  permission : String,
  model : String?,
  effort : String?,
  session : String?,
  task : String,
) -> String {
  let parts : Array[String] = [headless_bin]
  if permission == "write" {
    parts.push("--yolo")
  } else {
    parts.push("--permission")
    parts.push("readonly")
  }
  match model {
    Some(m) => {
      parts.push("--model")
      parts.push(m)
    }
    None => ()
  }
  match effort {
    Some(e) => {
      parts.push("--effort")
      parts.push(e)
    }
    None => ()
  }
  match session {
    Some(s) => {
      parts.push("--session")
      parts.push(s)
    }
    None => ()
  }
  parts.push("--")
  parts.push(herdr_shell_quote(task))
  parts.join(" ")
}

///|
priv struct HerdrPaneResult {
  answer : String
  child_session : String?
  failure : String?
}

///|
/// Parse the merged pane screen (the pty folds stdout and stderr together).
/// Text-mode headless prints `session: <id>` first, then the answer, then
/// the completion marker; the failure line replaces the answer block. The
/// answer is everything after the session line (or the whole screen when no
/// session line appeared) up to the FIRST terminal line (marker or failure):
/// the pane's shell re-draws a fresh prompt after the child exits, so
/// everything at or after the terminal line is prompt junk.
fn parse_pane_text(text : String) -> HerdrPaneResult {
  let lines : Array[String] = []
  for line in text.split("\n") {
    lines.push(line.to_owned())
  }
  let mut child_session : String? = None
  let mut session_idx = -1
  let mut failure : String? = None
  let mut failure_idx = -1
  let mut terminal_idx = -1
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    if child_session is None {
      match line.find(herdr_session_prefix) {
        Some(0) => {
          child_session = Some(line[herdr_session_prefix.length():].to_owned())
          session_idx = i
        }
        _ => ()
      }
    }
    if failure is None {
      match line.find(herdr_turn_failed_prefix) {
        Some(pos) => {
          failure = Some(
            line[pos + herdr_turn_failed_prefix.length():].to_owned(),
          )
          failure_idx = i
        }
        None => ()
      }
    }
    if terminal_idx < 0 {
      if line.contains(herdr_headless_marker) || failure_idx == i {
        terminal_idx = i
      }
    }
    i += 1
  }
  let kept : Array[String] = []
  let start = if session_idx >= 0 { session_idx + 1 } else { 0 }
  let end = if terminal_idx >= 0 { terminal_idx } else { lines.length() }
  let mut j = start
  while j < end {
    kept.push(lines[j])
    j += 1
  }
  { answer: kept.join("\n").trim().to_owned(), child_session, failure, }
}

///|
/// `wait-output` timeout shape: exit 1 with an error envelope whose code is
/// "timeout" on stderr.
fn is_timeout_error(exit : Int, stderr : String) -> Bool {
  exit == 1 && stderr.contains("\"code\":\"timeout\"")
}

///|
/// Bounded excerpt for model-visible errors; herdr's stderr JSON envelopes
/// can be long and the model only needs the head of them.
fn herdr_excerpt(text : String) -> String {
  let trimmed = text.trim().to_owned()
  if trimmed.length() > 200 {
    trimmed[:200].to_owned() + "..."
  } else {
    trimmed
  }
}

///|
/// Single-quote an argument for the shell command line built by `pane run`.
/// `'` inside the value is closed, escaped, and reopened.
fn herdr_shell_quote(s : String) -> String {
  "'" + s.replace(old="'", new="'\\''") + "'"
}
