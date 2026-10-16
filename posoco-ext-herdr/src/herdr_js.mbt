// js backend: env reads use the `process` global; the report spawn (herdr_channel_js.mbt)
// is detached and unref'd so reports are genuinely non-blocking.

///|
// Pure value pass-through: an Option never crosses the JS FFI (None is JS undefined,
// so a `?? null` fallback would decode as Some(null) and disable the env gate).
extern "js" fn node_env_get(name : String) -> String =
  #| (name) => process.env[name] ?? ""

///|
fn herdr_env(name : String) -> String? {
  let raw = node_env_get(name)
  if raw == "" {
    None
  } else {
    Some(raw)
  }
}

///|
#module("node:fs")
extern "js" fn fs_access_sync(path : String, mode : Int32) -> Unit = "accessSync"

///|
// which-probe for the bun runtime. The access function is passed in and the
// try/catch lives JS-side, so no exception crosses the FFI; 1 is the libuv
// access mask (fs.constants.X_OK === 1).
extern "js" fn node_path_executable(
  access : (String, Int32) -> Unit,
  path : String,
) -> Bool =
  #| (access, path) => {
  #|   try {
  #|     access(path, 1)
  #|     return true
  #|   } catch (_) {
  #|     return false
  #|   }
  #| }

///|
/// js which-probe behind the delegate registration precheck: an
/// executable-permission check per candidate path, resolution via PATH.
fn herdr_bin_runnable(bin : String) -> Bool {
  herdr_path_lookup(bin, herdr_env("PATH"), fn(path) {
    node_path_executable(fs_access_sync, path)
  })
}

///|
// JS-side catch mirrors the native side's ignored system() status: presence
// telemetry must never fail Agent composition.
extern "js" fn node_spawn_detached(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> NodeProc,
  bin : String,
  args : FixedArray[String],
) -> Unit =
  #| (spawn, bin, args) => {
  #|   try {
  #|     const child = spawn(bin, args, { detached: true, stdio: "ignore" })
  #|     child.unref()
  #|   } catch (_) {}
  #| }

///|
/// Build from the herdr environment without reporting; for exit paths that never
/// own an Agent (composition failure) yet must drop the authority detect() registered.
pub fn HerdrReporter::from_env() -> HerdrReporter? {
  match
    herdr_gate(
      herdr_env("HERDR_ENV"),
      herdr_env("HERDR_PANE_ID"),
      herdr_env("HERDR_BIN_PATH"),
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
fn herdr_spawn_report(bin : String, args : Array[String]) -> Unit {
  node_spawn_detached(cp_spawn, bin, FixedArray::from_array(args))
}
