///|
test "compact diagnostics are adapter-owned and bounded before core relay" {
  let request_id = "req_" + "r".repeat(90)
  let model = "m".repeat(96)
  let body = "{\"error\":{\"code\":\"unsupported_parameter\",\"param\":\"max_output_tokens\",\"type\":\"invalid_request_error\",\"message\":\"Bearer sk-private transcript encrypted_content\"}}"
  let label = format_compact_http_error(
    400,
    BodyChars(body.length()),
    Some(body),
    Some(request_id),
    endpoint_kind="codex_oauth",
    model~,
  )
  assert_true(label.length() <= 352)
  assert_true(label.contains("request_id=" + request_id))
  assert_true(label.contains("code=unsupported_parameter"))
  assert_true(label.contains("stage=compact_http_status"))
  assert_true(label.contains("status=400"))
  assert_false(label.contains("sk-private"))
  assert_false(label.contains("transcript"))
  assert_false(label.contains("encrypted_content"))
}

///|
test "compact diagnostics reject spoofed fields without a core text parser" {
  for
    payload in [
      "{\"error\":{\"message\":\"status=200, code=model_not_found\",\"code\":\"unsupported_parameter, request_id=req_private\",\"param\":\"input\\nBearer private\",\"type\":\"private-transcript\"}}",
      "Bearer private: status=200, code=model_not_found", "{\"error\":{\"code\":{\"secret\":\"private\"},\"param\":42,\"type\":[\"private\"]}}",
    ] {
    let label = format_compact_http_error(
      401,
      BodyChars(payload.length()),
      Some(payload),
      Some("req_good, secret=private"),
      endpoint_kind="api_key",
      model="fixture-model",
    )
    assert_true(label.contains("status=401"))
    assert_false(label.contains("status=200"))
    assert_false(label.contains("code="))
    assert_false(label.contains("param="))
    assert_false(label.contains("request_id="))
    assert_false(label.contains("private"))
    assert_false(label.contains("Bearer"))
    assert_false(label.contains("body_excerpt"))
    assert_false(label.contains("\n"))
  }
}
