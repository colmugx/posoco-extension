///|
/// Retry-contract pins: the router-level transient retry (posoco-ext-llm's
/// transient_retry_port wrapping every provider slot) decides purely from
/// @chatkit.is_transient_model_error over the message shapes this adapter and
/// posoco-kit-responses emit. These tests anchor the real constructors — not
/// copies of their wording — so a message edit that would silently disable
/// auto-retry (e.g. renaming stage=read_stream) fails here first.
///
/// Retryable by design: truncated SSE (marker-less EOF — today's shape for a
/// mid-stream connection reset until the upstream async fix surfaces the
/// underlying error), stage=read_stream, and gateway 408/5xx.
/// Never retryable: provider-declared failures, other 4xx, and the
/// pre-response transport stages (conservative by design, mirrors
/// kit-chat-completions transient.mbt).
test "truncated SSE (clean EOF) stays retry-classifiable" {
  match
    @responses.classify_stream_termination(
      provider="OpenAI",
      @responses.StreamTermination::CleanEof,
    ) {
    Some(err) => assert_true(@chatkit.is_transient_model_error(err))
    None => fail("clean EOF must classify as an error")
  }
}

///|
test "mid-stream read failures stay retry-classifiable" {
  let err = read_stream_transport_error(Failure::Failure("socket reset"))
  assert_true(@chatkit.is_transient_model_error(err))
}

///|
test "gateway 408/5xx stay retry-classifiable" {
  for status in [408, 500, 502, 503] {
    match classify_openai_http_status("http_status", status, BodyUnavailable) {
      Some(err) => assert_true(@chatkit.is_transient_model_error(err))
      None => fail("non-2xx must classify as an error")
    }
  }
}

///|
test "other HTTP 4xx stays non-retryable" {
  for status in [400, 401, 403, 404] {
    match classify_openai_http_status("http_status", status, BodyUnavailable) {
      Some(err) => assert_false(@chatkit.is_transient_model_error(err))
      None => fail("non-2xx must classify as an error")
    }
  }
}

///|
test "provider-declared SSE failure stays non-retryable" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let state = @responses.SseStreamState::SseStreamState()
  let failed_event = "{\"type\":\"response.failed\"}"
  try
    @responses.process_responses_sse(
      provider="OpenAI",
      failed_event,
      acc,
      _ => (),
      state~,
    )
  catch {
    err => assert_false(@chatkit.is_transient_model_error(err))
  } noraise {
    _ => fail("response.failed must raise a Transport error")
  }
}

///|
test "pre-response transport stages stay non-retryable" {
  // create_client can fail for a malformed base_url — retrying cannot fix it.
  let create_client = @posoco.ModelError::Transport(
    "OpenAI transport failure (stage=create_client): InvalidFormat",
  )
  // end_request covers connect/handshake/reset-while-awaiting-headers; the
  // predicate intentionally leaves it out (conservative-by-design). If this
  // pin flips to true, update kit-chat-completions transient.mbt first.
  let end_request = @posoco.ModelError::Transport(
    "OpenAI transport failure (stage=end_request): TypeError: reset",
  )
  assert_false(@chatkit.is_transient_model_error(create_client))
  assert_false(@chatkit.is_transient_model_error(end_request))
}
