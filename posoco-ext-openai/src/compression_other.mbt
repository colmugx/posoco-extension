///|
/// Wasm/llvm backends have no request codec; bodies always go uncompressed.
fn codex_compress_codec(raw : Bytes) -> (Bytes, String)? {
  let _ = raw
  None
}
