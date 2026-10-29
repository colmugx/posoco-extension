///|
test "truncated SSE parse failures are transient" {
  assert_true(
    is_transient_model_error(
      @posoco.ModelError::ResponseParse(
        "opencode-zen SSE truncated (stage=eof, terminal_marker=missing)",
      ),
    ),
  )
}

///|
test "mid-stream read resets are transient" {
  assert_true(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "opencode-zen transport failure (stage=read_stream)",
      ),
    ),
  )
}

///|
test "gateway 5xx statuses are transient" {
  assert_true(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "opencode-zen HTTP error (stage=chat_stream.http_status, status=503, body_bytes=175)",
      ),
    ),
  )
  assert_true(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "openai-compatible HTTP error (stage=chat.http_status, status=500, body=",
      ),
    ),
  )
  assert_true(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "kimi HTTP error (stage=chat_stream.http_status, status=502, body_bytes=64)",
      ),
    ),
  )
}

///|
test "request timeout 408 is transient" {
  assert_true(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "openai-compatible HTTP error (stage=chat.http_status, status=408, body=",
      ),
    ),
  )
}

///|
test "rate limit 429 is never transient" {
  assert_false(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "openai-compatible HTTP error (stage=chat.http_status, status=429, body=",
      ),
    ),
  )
}

///|
test "auth and other 4xx statuses are not transient" {
  assert_false(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "openai-compatible HTTP error (stage=chat.http_status, status=401, body=",
      ),
    ),
  )
  assert_false(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "openai-compatible HTTP error (stage=chat.http_status, status=403, body=",
      ),
    ),
  )
  assert_false(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "openai-compatible HTTP error (stage=chat.http_status, status=400, body=",
      ),
    ),
  )
  assert_false(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "openai-compatible HTTP error (stage=chat.http_status, status=404, body=",
      ),
    ),
  )
}

///|
test "unmarked connection-stage transport failures are transient" {
  // DNS resolution, connection refused, timeouts, socket resets before any
  // HTTP status exists — the network-noise class this ticket adds.
  for
    msg in [
      "connection reset", "dial tcp: lookup gateway.internal: no such host", "dial tcp 104.18.7.12:443: connect: connection refused",
      "opencode-zen transport failure (stage=post): TypeError: fetch failed", "DeepSeek transport failure (stage=post_stream): context deadline exceeded",
      "OpenAI transport failure (stage=end_request): socket hang up", "OpenAI transport failure (stage=write_body): broken pipe",
      "DeepSeek transport failure (stage=read_response)", "openrouter transport failure (stage=send_request): i/o timeout",
    ] {
    assert_true(is_transient_model_error(@posoco.ModelError::Transport(msg)))
  }
}

///|
test "provider-declared unmarked transport failures stay non-transient" {
  // The provider answered with a terminal failure — retrying cannot fix it.
  for
    msg in [
      "openai-compatible SSE stream failure (stage=error, category=provider_error, code=insufficient_quota)",
      "OpenAI SSE terminal failure (stage=response.failed, category=provider_error)",
      "OpenAI SSE terminal failure (stage=response.incomplete, category=not_completed)",
      "DeepSeek API error (stage=response.error, category=structured)",
    ] {
    assert_false(is_transient_model_error(@posoco.ModelError::Transport(msg)))
  }
}

///|
test "client construction and url shaping stay non-transient" {
  // Configuration errors retrying cannot fix.
  for
    msg in [
      "OpenAI transport failure (stage=create_client): InvalidFormat", "kimi transport failure (stage=split_url): invalid redirect uri",
    ] {
    assert_false(is_transient_model_error(@posoco.ModelError::Transport(msg)))
  }
}

///|
test "user cancellations are never transient" {
  // An intentional stop must never restart the turn (magpie guard mirror).
  for
    msg in [
      "magpie transport failure (stage=chat.post): The operation was aborted", "openai-compatible transport failure (stage=post): AbortError",
      "request canceled by user",
    ] {
    assert_false(is_transient_model_error(@posoco.ModelError::Transport(msg)))
  }
}

///|
test "marked statuses outrank the deterministic-text guards" {
  // A provider-declared SSE failure embedding a 5xx status keeps the
  // existing status-driven verdict (529 overloaded is transiently retried).
  assert_true(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "OpenAI SSE terminal failure (stage=error, category=provider_error, status=529): overloaded",
      ),
    ),
  )
  // A deterministic status stays deterministic even next to provider text.
  assert_false(
    is_transient_model_error(
      @posoco.ModelError::Transport(
        "OpenAI SSE terminal failure (stage=error, category=provider_error, status=400): bad request",
      ),
    ),
  )
}

///|
test "request build errors and ordinary parse failures are not transient" {
  assert_false(
    is_transient_model_error(
      @posoco.ModelError::RequestBuild("missing model id"),
    ),
  )
  assert_false(
    is_transient_model_error(
      @posoco.ModelError::ResponseParse(
        "kimi SSE parse failure (stage=json, payload_chars=12)",
      ),
    ),
  )
}

///|
test "status marker parsing tolerates malformed trailing text" {
  // Non-digit or short digit runs after the marker are not statuses.
  assert_false(transient_status("status=5"))
  assert_false(transient_status("status=51x"))
  assert_false(transient_status("no marker here"))
}
