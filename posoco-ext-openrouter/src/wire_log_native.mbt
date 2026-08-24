///|
/// wire_log_native.mbt — native twin of wire_log.js.mbt.
///
/// The wire log is currently js/bun-only: a native implementation needs
/// file/env APIs (moonbitlang/async/fs, moonbitlang/async/process) that
/// cannot join this package's imports without breaking the js build. On
/// native the wire log is disabled and both functions are no-ops.

///|
/// Always None on native: the wire log is unavailable (see file header).
fn wire_log_path() -> String? {
  None
}

///|
/// No-op on native (see file header).
fn wire_log_append(_path : String, _line : String) -> Unit {
  ()
}
