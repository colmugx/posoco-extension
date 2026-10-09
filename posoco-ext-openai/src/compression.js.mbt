///|
/// JS-backend codec: zstd through node:zlib (Bun/Node host), the same
/// transport optimization pi applies to the Codex SSE endpoint. Absent
/// runtime support or any compression failure returns `None` so the caller
/// sends the raw body unchanged.

///|
fn codex_compress_codec(raw : Bytes) -> (Bytes, String)? {
  if codex_zstd_available() {
    // Empty output signals a failed compression (a real zstd frame is never
    // empty); the shared strict-size gate rejects it either way.
    let compressed = codex_zstd_compress(raw)
    if compressed.length() > 0 {
      return Some((compressed, "zstd"))
    }
  }
  None
}

///|
extern "js" fn codex_zstd_available() -> Bool =
  #| () => {
  #|   try {
  #|     const zlib = process.getBuiltinModule("node:zlib");
  #|     return typeof zlib.zstdCompressSync === "function";
  #|   } catch {
  #|     return false;
  #|   }
  #| }

///|
extern "js" fn codex_zstd_compress(raw : Bytes) -> Bytes =
  #| (raw) => {
  #|   try {
  #|     return process.getBuiltinModule("node:zlib").zstdCompressSync(raw);
  #|   } catch {
  #|     return new Uint8Array(0);
  #|   }
  #| }
