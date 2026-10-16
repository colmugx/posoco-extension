///|
// Native backend. Detection reads the herdr-injected environment directly
// (@env, synchronous, no subprocess). Per-event reports run through libc
// system() with the command backgrounded and silenced: the sync Observer
// callback blocks only for the fork+exec of /bin/sh, at turn boundaries, and
// never propagates failure.

#borrow(cmd)
extern "C" fn ffi_system(cmd : Bytes) -> Int32 = "herdr_ffi_system"

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
  herdr_path_lookup(bin, @env.get_env_var("PATH"), fn(path) {
    ffi_access_x(herdr_c_string(path)) == 0
  })
}

///|
fn herdr_spawn_report(bin : String, args : Array[String]) -> Unit {
  let line = "\{[bin, ..args].map(fn(x) { herdr_shell_quote(x) }).join(" ")} >/dev/null 2>&1 &"
  ignore(ffi_system(herdr_c_string(line)))
}
