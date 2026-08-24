///|
// Bun is a global under bun (posoco-ext-bash precedent); Bun.env reads are
// synchronous, so detection needs no subprocess; Bun.spawn launches detached
// and returns immediately, so reports are genuinely non-blocking. The target
// runtime is bun — do not use node:child_process.

///|
// Pure value pass-through only — an Option never crosses the js FFI here
// (docs/questions.md 2026-08-19 stable boundaries): MoonBit None is encoded
// as JS undefined, so a `?? null` fallback would decode as Some(null) and
// disable the env gate entirely. Blank means missing.
extern "js" fn bun_env_get(name : String) -> String =
  #| (name) => Bun.env[name] ?? ""

///|
fn herdr_env(name : String) -> String? {
  let raw = bun_env_get(name)
  if raw == "" {
    None
  } else {
    Some(raw)
  }
}

///|
// The JS-side catch mirrors the native side's ignored system() status:
// presence telemetry must never fail Agent composition.
extern "js" fn bun_spawn_detached(bin : String, args : Array[String]) -> Unit =
  #| (bin, args) => {
  #|   try {
  #|     Bun.spawn({ cmd: [bin, ...args], stdout: "ignore", stderr: "ignore", stdin: "ignore" })
  #|   } catch (_) {}
  #| }

///|
pub fn HerdrReporter::detect() -> HerdrReporter? {
  match herdr_env("HERDR_ENV") {
    None => return None
    Some(_) => ()
  }
  let pane = match herdr_env("HERDR_PANE_ID") {
    Some(pane) => pane
    None => return None
  }
  let bin = match herdr_env("HERDR_BIN_PATH") {
    Some(bin) => bin
    None => "herdr"
  }
  let reporter = HerdrReporter::from_config({ pane, bin })
  reporter.emit(Idle)
  Some(reporter)
}

///|
fn herdr_spawn_report(bin : String, args : Array[String]) -> Unit {
  bun_spawn_detached(bin, args)
}
