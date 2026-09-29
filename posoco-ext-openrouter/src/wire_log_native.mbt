///|
/// Wire logging is js/bun-only; native and wasm use this no-op implementation.

///|
fn wire_log_path() -> String? {
  None
}

///|
fn wire_log_append(_path : String, _line : String) -> Unit {
  ()
}
