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
}

///|
test "unmarked transport failures are not transient" {
  assert_false(
    is_transient_model_error(@posoco.ModelError::Transport("connection reset")),
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
