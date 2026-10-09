///|
/// Native backend codec: gzip via the pure-MoonBit moonbit-community/flate
/// engine. The wire probe confirmed the Codex backend accepts
/// `Content-Encoding: gzip` on the streaming responses endpoint (plan
/// Phase 2 step 0). `@gzip.compress` is infallible; an oversized output is
/// rejected by the shared strict-size gate instead.
fn codex_compress_codec(raw : Bytes) -> (Bytes, String)? {
  Some((@gzip.gzip_compress(raw, level=6), "gzip"))
}
