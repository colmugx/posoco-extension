///|
/// The wire log is js/bun-only: a native implementation needs file/env APIs
/// (moonbitlang/async/fs, moonbitlang/async/process) that cannot join this
/// package's imports without breaking the js build.

///|
fn wire_log_path() -> String? {
  None
}

///|
fn wire_log_append(_path : String, _line : String) -> Unit {
  ()
}
