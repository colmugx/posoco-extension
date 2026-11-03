///|
// Native backend. Detection reads the herdr-injected environment directly
// (@env, synchronous, no subprocess). On Unix, reports use the existing
// backgrounded/silenced system() path. On Windows, the C shim uses
// CreateProcessW with argv quoting and redirected NUL handles. Both are
// best-effort, non-blocking from the Observer callback.

#borrow(cmd)
extern "C" fn ffi_system(cmd : Bytes) -> Int32 = "herdr_ffi_system"

///|
// Single compiled native package on Unix and Windows; the C shim chooses OS.
extern "C" fn ffi_windows_host() -> Int32 = "herdr_ffi_windows_host"

///|
#borrow(payload)
extern "C" fn ffi_win_spawn_report(payload : Bytes) -> Int32 = "herdr_ffi_win_spawn_report"

///|
fn herdr_c_string(s : String) -> Bytes {
  @utf8.encode(s + "\u{0}")
}

///|
/// Construct from the herdr environment without reporting anything — the
/// release-only counterpart of detect() (see herdr_js.mbt).
pub fn HerdrReporter::from_env() -> HerdrReporter? {
  match
    herdr_gate(
      @env.get_env_var("HERDR_ENV"),
      @env.get_env_var("HERDR_PANE_ID"),
      @env.get_env_var("HERDR_BIN_PATH"),
    ) {
    Some(cfg) => Some(HerdrReporter::from_config(cfg))
    None => None
  }
}

///|
pub fn HerdrReporter::detect() -> HerdrReporter? {
  let reporter = match HerdrReporter::from_env() {
    Some(reporter) => reporter
    None => return None
  }
  reporter.emit(Idle)
  Some(reporter)
}

///|
// One NUL per argv element plus an empty terminator. Embedded NUL characters
// in an untrusted report message must not turn it into extra argv elements.
fn herdr_report_argv_payload(bin : String, args : Array[String]) -> String {
  let nul = "\u{0}"
  [bin, ..args].map(fn(x) { x.replace(old=nul, new=" ") }).join(nul) + nul + nul
}

///|
fn herdr_spawn_report(bin : String, args : Array[String]) -> Unit {
  if ffi_windows_host() != 0 {
    // CreateProcessW receives real argv (with Unicode and Windows quoting)
    // rather than an interpolated cmd.exe line. Fire-and-forget telemetry.
    ignore(
      ffi_win_spawn_report(@utf8.encode(herdr_report_argv_payload(bin, args))),
    )
  } else {
    let line = "\{[bin, ..args].map(fn(x) { herdr_shell_quote(x) }).join(" ")} >/dev/null 2>&1 &"
    ignore(ffi_system(herdr_c_string(line)))
  }
}

///|
/// Single-quote one argv element for the Unix `system()` command line. `'`
/// inside the value is closed, escaped, and reopened.
fn herdr_shell_quote(s : String) -> String {
  "'" + s.replace(old="'", new="'\\''") + "'"
}
