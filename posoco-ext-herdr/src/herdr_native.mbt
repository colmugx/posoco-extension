///|
// Native backend. Detection reads the herdr-injected environment directly
// (@env, synchronous, no subprocess). Per-event reports run through libc
// system() with the command backgrounded and silenced: the sync Observer
// callback blocks only for the fork+exec of /bin/sh, at turn boundaries, and
// never propagates failure.

#borrow(cmd)
extern "C" fn ffi_system(cmd : Bytes) -> Int = "system"

///|
fn herdr_c_string(s : String) -> Bytes {
  @utf8.encode(s + "\u{0}")
}

///|
pub fn HerdrReporter::detect() -> HerdrReporter? {
  let reporter = match
    herdr_gate(
      @env.get_env_var("HERDR_ENV"),
      @env.get_env_var("HERDR_PANE_ID"),
      @env.get_env_var("HERDR_BIN_PATH"),
    ) {
    Some(cfg) => HerdrReporter::from_config(cfg)
    None => return None
  }
  reporter.emit(Idle)
  Some(reporter)
}

///|
fn herdr_spawn_report(bin : String, args : Array[String]) -> Unit {
  let line = "\{[bin, ..args].map(fn(x) { herdr_shell_quote(x) }).join(" ")} >/dev/null 2>&1 &"
  ignore(ffi_system(herdr_c_string(line)))
}

///|
/// Single-quote an argument for the shell command line built by the native
/// report path. `'` inside the value is closed, escaped, and reopened.
fn herdr_shell_quote(s : String) -> String {
  "'" + s.replace(old="'", new="'\\''") + "'"
}
