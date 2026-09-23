///|
/// The wire log is js/bun-only; wiring it for native+wasm needs @fs/@env
/// plumbing that has not been built yet, so it stays a no-op here.

///|
fn wire_log_path() -> String? {
  None
}

///|
fn wire_log_append(_path : String, _line : String) -> Unit {
  ()
}
