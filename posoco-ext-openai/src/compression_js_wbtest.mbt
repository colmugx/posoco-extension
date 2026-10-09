///|
/// JS-backend zstd codec tests: real node:zlib round-trip through the same
/// extern seam the request path uses.

///|
extern "js" fn js_zstd_decompress(raw : Bytes) -> Bytes =
  #| (raw) => process.getBuiltinModule("node:zlib").zstdDecompressSync(raw)

///|
test "zstd codec output decompresses to the raw bytes" {
  let raw = @utf8.encode(
    "{\"model\":\"gpt-5\",\"input\":[],\"stream\":true,\"store\":false}",
  )
  guard codex_compress_codec(raw) is Some((compressed, encoding)) else {
    fail("js runtime must provide zstd")
  }
  assert_eq(encoding, "zstd")
  assert_true(compressed.length() > 4)
  assert_eq(compressed[0], b'\x28')
  assert_eq(compressed[1], b'\xb5')
  assert_eq(compressed[2], b'\x2f')
  assert_eq(compressed[3], b'\xfd')
  assert_eq(js_zstd_decompress(compressed), raw)
}

///|
test "compressing the codex request yields the compressed wire payload" {
  let config = {
    ..OpenAIConfig::with_base_url(
      codex_js_test_token(),
      "gpt-5",
      codex_oauth_api_base(),
    ),
    account_id: Some("acct-js"),
  }
  // Production request bodies are kilobytes of JSON; mirror that so the
  // strict-size gate sees a realistic win instead of frame-header overhead.
  let filler = String::repeat("explain the following module: ", 200)
  let body = "{\"model\":\"gpt-5\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"\{filler}\"}]}],\"stream\":true,\"store\":false}"
  guard codex_stream_body(config, body) is Compressed(bytes, encoding) else {
    fail("codex endpoint must compress on the js runtime")
  }
  assert_eq(encoding, "zstd")
  assert_true(bytes.length() < body.length())
}

///|
/// The js test set cannot reuse the native wbtest fixture; any non-empty
/// bearer works because compression never inspects the credential.
fn codex_js_test_token() -> String {
  "js-test-token"
}

///|
test "seam refuses codec output that is not a strict size win" {
  // Incompressible input: zstd may return it at equal-or-greater size; the
  // shared gate must then report no compression. A one-byte body cannot win.
  guard codex_compress_request_body("x") is None else {
    fail("one-byte body must bypass compression")
  }
}
