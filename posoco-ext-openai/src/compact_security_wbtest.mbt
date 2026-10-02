///|
async test "openai_compact_error_structural_strings_and_429_cannot_echo_secrets" {
  let (outcomes, _) = compact_loopback_call_many([
    Respond(
      status=400,
      body="{\"error\":{\"message\":\"private-transcript\",\"code\":\"sk-live-secret\",\"param\":\"encrypted-payload\",\"type\":\"credential-secret\"}}",
      headers=[("x-request-id", "sk-header-secret")],
      delay_ms=0,
    ),
    Respond(
      status=429,
      body="{\"error\":{\"message\":\"private-transcript sk-live-secret\",\"code\":\"sk-live-secret\",\"type\":\"rate_limit_error\"}}",
      headers=[("Retry-After", "7")],
      delay_ms=0,
    ),
  ])
  guard outcomes[0] is Err(@posoco.ModelError::Transport(message)) else {
    fail("400")
  }
  for
    secret in [
      "private-transcript", "sk-live-secret", "encrypted-payload", "credential-secret",
      "sk-header-secret",
    ] {
    assert_false(message.contains(secret))
  }
  guard outcomes[1] is Err(@posoco.ModelError::RateLimited(info)) else {
    fail("429")
  }
  assert_false(info.message.contains("private-transcript"))
  assert_false(info.message.contains("sk-live-secret"))
  assert_eq(info.provider_code, None)
  assert_true(info.reset_at_ms is Some(_))
}
