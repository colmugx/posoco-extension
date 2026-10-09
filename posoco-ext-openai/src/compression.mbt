///|
/// Compressed request-body seam for Codex streaming requests. Compression is
/// an optimization, never a correctness dependency: every failure path ends
/// in an uncompressed send (matching pi's compressRequestBodyZstd fallback).

///|
/// Wire payload for one streaming request: either the plain JSON text or
/// codec output paired with the exact `Content-Encoding` label to declare.
priv enum StreamBody {
  Plain(String)
  Compressed(Bytes, String)
}

///|
/// Compress a streaming request body when the current target has a codec and
/// the encoded output is actually smaller than the raw UTF-8 bytes. Only the
/// Codex subscription backend participates; the ordinary API contract stays
/// uncompressed.
fn codex_stream_body(config : OpenAIConfig, body_text : String) -> StreamBody {
  if config.base_url == codex_oauth_api_base() {
    match codex_compress_request_body(body_text) {
      Some((bytes, encoding)) => return Compressed(bytes, encoding)
      None => ()
    }
  }
  Plain(body_text)
}

///|
/// Declare `Content-Encoding` on the request headers exactly when the payload
/// is compressed.
fn codex_apply_body_headers(headers : @http.Headers, body : StreamBody) -> Unit {
  match body {
    Compressed(_, encoding) =>
      headers[@http.CaseInsensitiveString("Content-Encoding")] = encoding
    Plain(_) => ()
  }
}

///|
/// Shared gate: encode once, keep the codec output only when it is a strict
/// size win. `codex_compress_codec` is the per-target implementation.
fn codex_compress_request_body(text : String) -> (Bytes, String)? {
  let raw = @utf8.encode(text)
  match codex_compress_codec(raw) {
    Some((bytes, encoding)) if bytes.length() < raw.length() =>
      Some((bytes, encoding))
    _ => None
  }
}
