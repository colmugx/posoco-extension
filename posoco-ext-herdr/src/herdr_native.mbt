///|
// Native backend. Detection shells out once (async @process) to read the
// herdr-injected environment. Per-event reports run through libc system()
// with the command backgrounded and silenced: the sync Observer callback
// blocks only for the fork+exec of /bin/sh, at turn boundaries, and never
// propagates failure.

#borrow(cmd)
extern "C" fn ffi_system(cmd : Bytes) -> Int = "system"

///|
fn herdr_c_string(s : String) -> Bytes {
  @utf8.encode(s + "\u{0}")
}

///|
pub async fn HerdrReporter::detect() -> HerdrReporter? noraise {
  let reporter = match herdr_detect() {
    Some(cfg) => HerdrReporter::from_config(cfg)
    None => return None
  }
  reporter.emit(Idle)
  Some(reporter)
}

///|
async fn herdr_detect() -> HerdrConfig? noraise {
  // Exactly three lines, no trailing newline: gate marker, pane id, bin.
  let script = "printf '%s\\n%s\\n%s' \"$HERDR_ENV\" \"$HERDR_PANE_ID\" \"${HERDR_BIN_PATH:-herdr}\""
  let (_, out) = @process.collect_stdout("sh", ["-c", script]) catch {
    _ => return None
  }
  let text = out.text() catch { _ => return None }
  let parts = text.split("\n").collect()
  guard parts.length() == 3 else { return None }
  let marker = parts[0]
  let pane = parts[1].to_owned()
  let bin = parts[2].to_owned()
  if marker == "" || pane == "" {
    return None
  }
  if bin == "" {
    return Some({ pane, bin: "herdr" })
  }
  Some({ pane, bin })
}

///|
fn herdr_spawn_report(bin : String, args : Array[String]) -> Unit {
  let parts : Array[String] = [herdr_shell_quote(bin)]
  for arg in args {
    parts.push(herdr_shell_quote(arg))
  }
  let line = parts.join(" ") + " >/dev/null 2>&1 &"
  ignore(ffi_system(herdr_c_string(line)))
}
