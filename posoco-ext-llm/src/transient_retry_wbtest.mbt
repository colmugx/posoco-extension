///|
/// Inner fake whose `chat`/`compact` fail with `error` until
/// `failures_left` is exhausted, then succeed. Counters record every call.
struct FakeModelPort {
  chat_calls : Ref[Int32]
  compact_calls : Ref[Int32]
  compact_tools : Array[Array[@posoco.ToolDef]]
  chat_failures_left : Ref[Int32]
  compact_failures_left : Ref[Int32]
  error : @posoco.ModelError
}

///|
fn FakeModelPort::FakeModelPort(
  chat_failures : Int32,
  error : @posoco.ModelError,
) -> FakeModelPort {
  FakeModelPort::{
    chat_calls: Ref::{ val: 0, },
    compact_calls: Ref::{ val: 0, },
    compact_tools: [],
    chat_failures_left: Ref::{ val: chat_failures, },
    compact_failures_left: Ref::{ val: 0, },
    error,
  }
}

///|
fn FakeModelPort::with_compact_failures(
  self : FakeModelPort,
  failures : Int32,
) -> FakeModelPort {
  self.compact_failures_left.val = failures
  self
}

///|
impl @posoco.ModelPort for FakeModelPort with fn chat(
  self : FakeModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.chat_calls.val += 1
  if self.chat_failures_left.val > 0 {
    self.chat_failures_left.val -= 1
    raise self.error
  }
  let completion = @posoco.Completion::Completion(
    content=[@posoco.Content::Text("recovered")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  @posoco.ModelCallResult::{ completion, processed_messages: [], }
}

///|
impl @posoco.ModelPort for FakeModelPort with fn compact(
  self : FakeModelPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  self.compact_calls.val += 1
  self.compact_tools.push(tools.copy())
  if self.compact_failures_left.val > 0 {
    self.compact_failures_left.val -= 1
    raise self.error
  }
  @posoco.CompactResult::{
    compacted_messages: [
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("summary")]),
    ],
    mode: @posoco.CompactMode::Replace,
  }
}

///|
impl @posoco.ModelPort for FakeModelPort with fn provider_config(
  _self : FakeModelPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=[],
    context_window=Some(28_000),
  )
}

///|
let flaky_error_truncated : @posoco.ModelError = @posoco.ModelError::ResponseParse(
  "opencode-zen SSE truncated (stage=eof, terminal_marker=missing)",
)

///|
fn flaky_scope() -> @posoco.InvocationScope {
  @posoco.InvocationScope::{
    session_id: @posoco.SessionId::unchecked("retry-test"),
    run_id: @posoco.RunId::unchecked("run-1"),
    effect_id: None,
    pressure: None,
  }
}

///|
fn flaky_options() -> @posoco.ChatOptions {
  @posoco.ChatOptions::{ temperature: None, max_output_tokens: None, }
}

///|
/// Zero-delay policy so tests don't wait out the backoff.
fn zero_delay_policy() -> TransientRetryPolicy {
  { max_retries: 3, initial_delay_ms: 0, }
}

///|
/// The default retry budget (10 retries) at zero delay: pins the
/// 1 initial attempt + up to 10 retries contract without real waiting.
fn default_zero_delay_policy() -> TransientRetryPolicy {
  { max_retries: 10, initial_delay_ms: 0, }
}

///|
test "default policy retries up to 10 times with fibonacci backoff" {
  let policy = TransientRetryPolicy::default()
  assert_eq(policy.max_retries, 10)
  assert_eq(policy.initial_delay_ms, 1000)
  let expected_ms : Array[Int32] = [
    1000, 2000, 3000, 5000, 8000, 13000, 21000, 34000, 55000, 89000,
  ]
  for i, delay_ms in expected_ms {
    assert_eq(policy.delay_ms(i), delay_ms)
  }
  assert_eq(policy.total_backoff_ms(), 231000)
}

///|
test "fibonacci backoff follows the initial delay" {
  let policy : TransientRetryPolicy = {
    max_retries: 10,
    initial_delay_ms: 2000,
  }
  assert_eq(policy.delay_ms(0), 2000)
  assert_eq(policy.delay_ms(1), 4000)
  assert_eq(policy.delay_ms(2), 6000)
  assert_eq(policy.delay_ms(3), 10000)
  assert_eq(policy.total_backoff_ms(), 462000)
}

///|
test "exhausted marker names the retry count and total backoff" {
  let marked = exhausted_retries_error(
    TransientRetryPolicy::default(),
    @posoco.ModelError::Transport("dial tcp: connect: connection refused"),
  )
  match marked {
    @posoco.ModelError::Transport(msg) => {
      assert_true(
        msg.contains(
          "transient retries exhausted after 10 retries (total backoff 231s)",
        ),
      )
      // The original failure text is preserved for diagnostics.
      assert_true(msg.contains("dial tcp: connect: connection refused"))
    }
    other => fail("transport error must stay a transport error: \{other}")
  }
  // The wrapper keeps the variant, so downstream classification is stable.
  assert_true(@chatkit.is_transient_model_error(marked))
  match
    exhausted_retries_error(
      TransientRetryPolicy::default(),
      @posoco.ModelError::ResponseParse("opencode-zen SSE truncated"),
    ) {
    @posoco.ModelError::ResponseParse(msg) =>
      assert_true(msg.contains("transient retries exhausted after 10 retries"))
    other => fail("parse error must stay a parse error: \{other}")
  }
  // Non-retried classes pass through untouched.
  let rate_limited : @posoco.ModelError = @posoco.ModelError::RateLimited({
    message: "quota",
    reset_at_ms: None,
    provider_code: Some("429"),
  })
  match exhausted_retries_error(TransientRetryPolicy::default(), rate_limited) {
    @posoco.ModelError::RateLimited(_) => ()
    other => fail("rate limited must pass through: \{other}")
  }
}

///|
async test "transient retry retries truncated SSE failures until success" {
  let inner = FakeModelPort::FakeModelPort(2, flaky_error_truncated)
  let port : &@posoco.ModelPort = transient_retry_port(
    inner~,
    policy=zero_delay_policy(),
  )
  let result = port.chat(
    flaky_scope(),
    [],
    [],
    flaky_options(),
    @posoco.StreamMode::NoStream,
  )
  assert_eq(result.completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_eq(inner.chat_calls.val, 3)
}

///|
async test "transient retry gives up after the retry budget" {
  let inner = FakeModelPort::FakeModelPort(99, flaky_error_truncated)
  let port : &@posoco.ModelPort = transient_retry_port(
    inner~,
    policy=default_zero_delay_policy(),
  )
  let result = Ok(
    port.chat(
      flaky_scope(),
      [],
      [],
      flaky_options(),
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => fail("expected the truncation error after the retry budget")
    Err(error) =>
      match error {
        @posoco.ModelError::ResponseParse(msg) => {
          assert_true(
            msg.contains("transient retries exhausted after 10 retries"),
          )
          assert_true(msg.contains("SSE truncated"))
        }
        other => fail("expected the parse error shape: \{other}")
      }
  }
  // 1 initial attempt + 10 retries.
  assert_eq(inner.chat_calls.val, 11)
}

///|
async test "transient retry retries mid-stream transport failures" {
  let inner = FakeModelPort::FakeModelPort(
    1,
    @posoco.ModelError::Transport(
      "opencode-zen transport failure (stage=read_stream)",
    ),
  )
  let port : &@posoco.ModelPort = transient_retry_port(
    inner~,
    policy=zero_delay_policy(),
  )
  let result = port.chat(
    flaky_scope(),
    [],
    [],
    flaky_options(),
    @posoco.StreamMode::NoStream,
  )
  assert_eq(result.completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_eq(inner.chat_calls.val, 2)
}

///|
/// Connection-establishment failures (DNS, refused, timeouts) carry no HTTP
/// status marker — the new retryable class this ticket adds.
async test "transient retry retries connection-stage transport failures" {
  let refused = FakeModelPort::FakeModelPort(
    1,
    @posoco.ModelError::Transport(
      "opencode-zen transport failure (stage=post): dial tcp 104.18.7.12:443: connect: connection refused",
    ),
  )
  let port : &@posoco.ModelPort = transient_retry_port(
    inner=refused,
    policy=zero_delay_policy(),
  )
  let result = port.chat(
    flaky_scope(),
    [],
    [],
    flaky_options(),
    @posoco.StreamMode::NoStream,
  )
  assert_eq(result.completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_eq(refused.chat_calls.val, 2)
  let timed_out = FakeModelPort::FakeModelPort(
    2,
    @posoco.ModelError::Transport(
      "DeepSeek transport failure (stage=post_stream): context deadline exceeded",
    ),
  )
  let port : &@posoco.ModelPort = transient_retry_port(
    inner=timed_out,
    policy=default_zero_delay_policy(),
  )
  let result = port.chat(
    flaky_scope(),
    [],
    [],
    flaky_options(),
    @posoco.StreamMode::NoStream,
  )
  assert_eq(result.completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_eq(timed_out.chat_calls.val, 3)
}

///|
/// Deterministic 4xx verdicts surface immediately — no retry, no waiting,
/// and the error text passes through unmarked (no exhausted marker).
async test "transient retry never retries deterministic client errors" {
  for status in [400, 401, 403, 404] {
    let inner = FakeModelPort::FakeModelPort(
      1,
      @posoco.ModelError::Transport(
        "openai-compatible HTTP error (stage=chat.http_status, status=\{status}, body=",
      ),
    )
    let port : &@posoco.ModelPort = transient_retry_port(
      inner~,
      policy=default_zero_delay_policy(),
    )
    let result = Ok(
      port.chat(
        flaky_scope(),
        [],
        [],
        flaky_options(),
        @posoco.StreamMode::NoStream,
      ),
    ) catch {
      error => Err(error)
    }
    match result {
      Ok(_) => fail("expected the \{status} error to surface unretried")
      Err(error) =>
        match error {
          @posoco.ModelError::Transport(msg) =>
            assert_false(msg.contains("exhausted"))
          other => fail("expected the transport shape: \{other}")
        }
    }
    assert_eq(inner.chat_calls.val, 1)
  }
}

///|
/// User-initiated cancellations must never restart the turn, even when the
/// provider surfaces them as plain transport failures.
async test "transient retry never retries user cancellations" {
  let cancelled = FakeModelPort::FakeModelPort(
    1,
    @posoco.ModelError::Transport(
      "magpie transport failure (stage=chat.post): The operation was aborted",
    ),
  )
  let port : &@posoco.ModelPort = transient_retry_port(
    inner=cancelled,
    policy=default_zero_delay_policy(),
  )
  let result = Ok(
    port.chat(
      flaky_scope(),
      [],
      [],
      flaky_options(),
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => fail("expected the cancellation to surface unretried")
    Err(_) => ()
  }
  assert_eq(cancelled.chat_calls.val, 1)
}

///|
async test "transient retry retries gateway 503 responses until success" {
  let inner = FakeModelPort::FakeModelPort(
    2,
    @posoco.ModelError::Transport(
      "opencode-zen HTTP error (stage=chat_stream.http_status, status=503, body_bytes=175, body_category=utf8)",
    ),
  )
  let port : &@posoco.ModelPort = transient_retry_port(
    inner~,
    policy=zero_delay_policy(),
  )
  let result = port.chat(
    flaky_scope(),
    [],
    [],
    flaky_options(),
    @posoco.StreamMode::NoStream,
  )
  assert_eq(result.completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_eq(inner.chat_calls.val, 3)
}

///|
async test "transient retry does not retry other http statuses" {
  let inner = FakeModelPort::FakeModelPort(
    1,
    @posoco.ModelError::Transport(
      "opencode-zen HTTP error (stage=chat_stream.http_status, status=400, body=bad request)",
    ),
  )
  let port : &@posoco.ModelPort = transient_retry_port(
    inner~,
    policy=zero_delay_policy(),
  )
  let result = Ok(
    port.chat(
      flaky_scope(),
      [],
      [],
      flaky_options(),
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => fail("expected the 400 error to surface unretried")
    Err(_) => ()
  }
  assert_eq(inner.chat_calls.val, 1)
}

///|
async test "transient retry never retries rate limit errors" {
  // 429 belongs to the rate-limit resume domain (posoco-ext-ratelimit), not
  // to request-level retrying — in either error shape.
  let transport_429 = FakeModelPort::FakeModelPort(
    1,
    @posoco.ModelError::Transport(
      "openai-compatible HTTP error (stage=chat.http_status, status=429, body=",
    ),
  )
  let port : &@posoco.ModelPort = transient_retry_port(
    inner=transport_429,
    policy=zero_delay_policy(),
  )
  let result = Ok(
    port.chat(
      flaky_scope(),
      [],
      [],
      flaky_options(),
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => fail("expected the 429 transport error to surface unretried")
    Err(_) => ()
  }
  assert_eq(transport_429.chat_calls.val, 1)
  let rate_limited = FakeModelPort::FakeModelPort(
    1,
    @posoco.ModelError::RateLimited({
      message: "quota exhausted",
      reset_at_ms: None,
      provider_code: Some("429"),
    }),
  )
  let port : &@posoco.ModelPort = transient_retry_port(
    inner=rate_limited,
    policy=zero_delay_policy(),
  )
  let result = Ok(
    port.chat(
      flaky_scope(),
      [],
      [],
      flaky_options(),
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => fail("expected the RateLimited error to surface unretried")
    Err(_) => ()
  }
  assert_eq(rate_limited.chat_calls.val, 1)
}

///|
async test "transient retry retries transient failures during compact" {
  let inner = FakeModelPort::FakeModelPort(0, flaky_error_truncated).with_compact_failures(
    1,
  )
  let port : &@posoco.ModelPort = transient_retry_port(
    inner~,
    policy=zero_delay_policy(),
  )
  let tools = [@posoco.tk_tool_def("echo", "compact context")]
  let result = port.compact(
    flaky_scope(),
    [],
    tools,
    flaky_options(),
    @posoco.CompactTrigger::Manual,
  )
  assert_true(result.mode == @posoco.CompactMode::Replace)
  // 1 failed compact attempt + 1 successful retry.
  assert_eq(inner.compact_calls.val, 2)
  assert_true(inner.compact_tools == [tools, tools])
  assert_eq(inner.chat_calls.val, 0)
}

///|
/// Compact rides the same policy as chat: unmarked connection-stage
/// transport failures retry under the shared budget.
async test "transient retry retries connection-stage failures during compact" {
  let inner = FakeModelPort::FakeModelPort(
    0,
    @posoco.ModelError::Transport(
      "openrouter transport failure (stage=compact_post): dial tcp: no such host",
    ),
  ).with_compact_failures(1)
  let port : &@posoco.ModelPort = transient_retry_port(
    inner~,
    policy=zero_delay_policy(),
  )
  let result = port.compact(
    flaky_scope(),
    [],
    [],
    flaky_options(),
    @posoco.CompactTrigger::Manual,
  )
  assert_true(result.mode == @posoco.CompactMode::Replace)
  assert_eq(inner.compact_calls.val, 2)
}

///|
async test "transient retry gives up compact after the retry budget" {
  let inner = FakeModelPort::FakeModelPort(0, flaky_error_truncated).with_compact_failures(
    99,
  )
  let port : &@posoco.ModelPort = transient_retry_port(
    inner~,
    policy=default_zero_delay_policy(),
  )
  let result = Ok(
    port.compact(
      flaky_scope(),
      [],
      [],
      flaky_options(),
      @posoco.CompactTrigger::Manual,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) =>
      fail("expected the truncation error after the compact retry budget")
    Err(error) =>
      match error {
        @posoco.ModelError::ResponseParse(msg) =>
          assert_true(
            msg.contains("transient retries exhausted after 10 retries"),
          )
        other => fail("expected the parse error shape: \{other}")
      }
  }
  // 1 initial attempt + 10 retries, same budget as chat.
  assert_eq(inner.compact_calls.val, 11)
}

///|
async test "router compact forwards explicit tools to the active slot without chat" {
  let first = FakeModelPort::FakeModelPort(0, flaky_error_truncated)
  let second = FakeModelPort::FakeModelPort(0, flaky_error_truncated)
  let router = RouterModelPort(slots=[
    ModelSlot::ModelSlot(
      id="first",
      label="first",
      provider_id="one",
      model_id="model-a",
      port=first,
    ),
    ModelSlot::ModelSlot(
      id="second",
      label="second",
      provider_id="two",
      model_id="model-b",
      port=second,
    ),
  ])
  let port : &@posoco.ModelPort = router
  let tools = [@posoco.tk_tool_def("echo", "snapshot tools")]
  ignore(
    port.compact(
      flaky_scope(),
      [],
      tools,
      flaky_options(),
      @posoco.CompactTrigger::Manual,
    ),
  )
  router.switch_slot("second")
  ignore(
    port.compact(
      flaky_scope(),
      [],
      [],
      flaky_options(),
      @posoco.CompactTrigger::Auto,
    ),
  )
  assert_true(first.compact_tools == [tools])
  assert_true(second.compact_tools == [[]])
  assert_eq(first.chat_calls.val, 0)
  assert_eq(second.chat_calls.val, 0)
}

///|
async test "provider_config passes through to the inner port" {
  let inner = FakeModelPort::FakeModelPort(0, flaky_error_truncated)
  let port : &@posoco.ModelPort = transient_retry_port(
    inner~,
    policy=zero_delay_policy(),
  )
  assert_eq(port.provider_config().context_window, Some(28_000))
  assert_eq(inner.chat_calls.val, 0)
}
