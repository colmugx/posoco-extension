///|
/// Native+wasm twin of wire_log.js.mbt.
///
/// The wire log is currently js/bun-only; wiring it for native+wasm needs
/// @fs/@env plumbing that has not been built yet. On native and wasm the
/// wire log is disabled and both functions are no-ops.

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
