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
#borrow(bin)
extern "C" fn ffi_win_bin_runnable(bin : Bytes) -> Int32 = "herdr_ffi_win_bin_runnable"

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
// access(X_OK) rides the same prefixed-shim seam as system(): moonc emits a
// prototype for every extern binding, and binding libc's own `access` name
// would collide with the platform declaration.
#borrow(path)
extern "C" fn ffi_access_x(path : Bytes) -> Int32 = "herdr_ffi_access_x"

///|
/// Native which-probe behind the delegate registration precheck: an
/// executable-permission check per candidate path, resolution via PATH.
fn herdr_bin_runnable(bin : String) -> Bool {
  if ffi_windows_host() != 0 {
    // SearchPathW respects the Windows PATH separator and .exe extension.
    return ffi_win_bin_runnable(herdr_c_string(bin)) == 0
  }
  herdr_path_lookup(bin, @env.get_env_var("PATH"), fn(path) {
    ffi_access_x(herdr_c_string(path)) == 0
  })
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
