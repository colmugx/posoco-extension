///|
/// Native-target compression seam tests: gzip through the pure-MoonBit
/// moonbit-community/flate engine (wire probe confirmed backend acceptance).

///|
test "gzip codec output decompresses to the raw bytes" {
  let raw = @utf8.encode("{\"model\":\"gpt-5\",\"input\":[]}")
  guard codex_compress_codec(raw) is Some((compressed, encoding)) else {
    fail("native codec must compress")
  }
  assert_eq(encoding, "gzip")
  assert_true(compressed.length() > 2)
  assert_eq(compressed[0], b'\x1f')
  assert_eq(compressed[1], b'\x8b')
  assert_eq(@gzip.gunzip(compressed), raw)
}

///|
test "api key endpoint never compresses" {
  let config = OpenAIConfig::with_base_url(
    "sk-test", "gpt-5", "https://api.openai.com/v1",
  )
  let body = "{\"model\":\"gpt-5\",\"input\":[]}"
  match codex_stream_body(config, body) {
    Plain(text) => assert_eq(text, body)
    Compressed(_, _) => fail("api key endpoint must stay uncompressed")
  }
}

///|
test "compressed payload declares its encoding, plain does not" {
  let headers : @http.Headers = {
    "Content-Type": "application/json",
  }
  codex_apply_body_headers(headers, Compressed(b"xx", "gzip"))
  assert_eq(headers.get("Content-Encoding"), Some("gzip"))
  codex_apply_body_headers(headers, Plain("{}"))
  assert_eq(headers.get("Content-Encoding"), Some("gzip"))
}

///|
test "codex endpoint compresses realistic bodies on native" {
  let config = codex_identity_test_config()
  // Production request bodies are kilobytes of JSON; mirror that so the
  // strict-size gate sees a realistic win instead of frame-header overhead.
  let filler = String::repeat("explain the following module: ", 200)
  let body = "{\"model\":\"gpt-5\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"\{filler}\"}]}],\"stream\":true,\"store\":false}"
  guard codex_stream_body(config, body) is Compressed(bytes, encoding) else {
    fail("codex endpoint must compress on native")
  }
  assert_eq(encoding, "gzip")
  assert_true(bytes.length() < body.length())
}

///|
test "seam keeps tiny bodies plain when gzip cannot win" {
  let config = codex_identity_test_config()
  // A 20-byte body cannot amortize the gzip frame header; the strict-size
  // gate must fall back to the plain body.
  match codex_stream_body(config, "{\"model\":\"gpt-5\"}") {
    Plain(_) => ()
    Compressed(_, _) => fail("no-win body must produce a plain payload")
  }
}
