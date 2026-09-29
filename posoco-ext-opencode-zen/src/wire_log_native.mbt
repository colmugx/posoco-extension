///|
/// Native+wasm twin of wire_log.js.mbt.
///
/// Wire logging is js/bun-only. On native and wasm it is disabled and both
/// functions are no-ops.

///|
/// Always None on native+wasm: the wire log is unavailable (see file header).
fn wire_log_path() -> String? {
  None
}

///|
/// No-op on native+wasm (see file header).
fn wire_log_append(_path : String, _line : String) -> Unit {
  ()
}
