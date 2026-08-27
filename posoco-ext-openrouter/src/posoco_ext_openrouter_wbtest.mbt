///|
/// Blackbox tests for posoco-ext-openrouter.
///
/// These exercise the pure config/build/encode/decode logic without any
/// network calls. Streaming and live HTTP behavior land in stage 5.

///|
fn user_msg(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
fn chat_options() -> @posoco.ChatOptions {
  { temperature: None, max_output_tokens: None }
}

///|
test "OpenRouterConfig records required fields and the default base_url" {
  let config = OpenRouterConfig(
    "sk-or-test",
    model="anthropic/claude-3.7-sonnet",
  )
  assert_eq(config.api_key, "sk-or-test")
  assert_eq(config.base_url, "https://openrouter.ai/api/v1")
  assert_eq(config.model, "anthropic/claude-3.7-sonnet")
  assert_false(config.thinking)
  assert_eq(config.reasoning_effort, None)
  assert_eq(config.http_referer, None)
  assert_eq(config.title, None)
}

///|
test "OpenRouterConfig carries optional fields" {
  let config = OpenRouterConfig(
    "sk-or-test",
    model="anthropic/claude-3.7-sonnet",
    base_url="https://proxy.example.com/v1",
    thinking=true,
    reasoning_effort=Some("high"),
    context_window=Some(200000),
    compact_threshold=Some(0.85),
    http_referer=Some("https://myapp.example"),
    title=Some("My App"),
  )
  assert_eq(config.base_url, "https://proxy.example.com/v1")
  assert_true(config.thinking)
  assert_eq(config.reasoning_effort, Some("high"))
  assert_eq(config.context_window, Some(200000))
  assert_eq(config.compact_threshold, Some(0.85))
  assert_eq(config.http_referer, Some("https://myapp.example"))
  assert_eq(config.title, Some("My App"))
}

///|
test "OpenRouterModelPort exposes config passthrough via provider_config" {
  let config = OpenRouterConfig(
    "sk-or-test",
    model="anthropic/claude-3.7-sonnet",
    context_window=Some(131072),
    compact_threshold=Some(0.9),
  )
  let port = OpenRouterModelPort(config)
  let pc = @posoco.ModelPort::provider_config(port)
  assert_eq(pc.context_window, Some(131072))
  assert_eq(pc.compact_threshold, Some(0.9))
  assert_eq(pc.reasoning_effort_values, [])
}

///|
test "OpenRouterConfig::with_reasoning_effort maps the selector vocabulary" {
  let config = OpenRouterConfig(
    "sk-or-test",
    model="qwen/qwen3-max",
    thinking=true,
    reasoning_effort=Some("high"),
    thinking_efforts=["minimal", "low", "high", "max"],
  )
  let off = config.with_reasoning_effort("off")
  assert_false(off.thinking)
  assert_eq(off.reasoning_effort, None)
  let low = config.with_reasoning_effort("low")
  assert_true(low.thinking)
  assert_eq(low.reasoning_effort, Some("low"))
  let invalid = Ok(config.with_reasoning_effort("xhigh")) catch {
    err => Err(err)
  }
  match invalid {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      assert_eq(manifest_id, "posoco_ext_openrouter")
      assert_true(detail.contains("unsupported reasoning effort"))
    }
    _ => fail("an undeclared effort must fail at the config boundary")
  }
  let on_with_levels = Ok(config.with_reasoning_effort("on")) catch {
    err => Err(err)
  }
  match on_with_levels {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("unsupported reasoning effort"))
    _ => fail("'on' must be rejected while explicit levels are declared")
  }
}

///|
test "'on' selects plain thinking when no levels are declared" {
  let config = OpenRouterConfig("sk-or-test", model="qwen/qwen3-max")
  let on = config.with_reasoning_effort("on")
  assert_true(on.thinking)
  assert_eq(on.reasoning_effort, None)
  let off = on.with_reasoning_effort("off")
  assert_false(off.thinking)
  assert_eq(off.reasoning_effort, None)
}

///|
test "build_chat_request omits include_reasoning when off and sends it verbatim when on" {
  let opts = chat_options()
  // thinking off: neither field may appear.
  let off_body = build_chat_request(
    OpenRouterConfig("k", model="m"),
    [user_msg("hi")],
    [],
    opts,
    false,
  )
  guard off_body is Object(off_fields) else {
    fail("expected request to be an object")
  }
  match off_fields.get("include_reasoning") {
    None => ()
    Some(_) => fail("include_reasoning must be omitted entirely when off")
  }
  match off_fields.get("reasoning_effort") {
    None => ()
    Some(_) => fail("reasoning_effort must be omitted when off")
  }

  // thinking on without a level: include_reasoning true, no reasoning_effort.
  let on_body = build_chat_request(
    OpenRouterConfig("k", model="m", thinking=true),
    [user_msg("hi")],
    [],
    opts,
    false,
  )
  guard on_body is Object(on_fields) else {
    fail("expected request to be an object")
  }
  match on_fields.get("include_reasoning") {
    Some(value) => assert_eq(value.stringify(), "true")
    None => fail("expected include_reasoning=true when thinking is on")
  }
  match on_fields.get("reasoning_effort") {
    None => ()
    Some(_) => fail("reasoning_effort must be omitted without a level")
  }

  // thinking on plus a declared level: both fields present, effort verbatim.
  let effort_body = build_chat_request(
    OpenRouterConfig(
      "k",
      model="m",
      thinking=true,
      reasoning_effort=Some("high"),
    ),
    [user_msg("hi")],
    [],
    opts,
    false,
  )
  guard effort_body is Object(effort_fields) else {
    fail("expected request to be an object")
  }
  match effort_fields.get("include_reasoning") {
    Some(value) => assert_eq(value.stringify(), "true")
    None => fail("expected include_reasoning=true with a level selected")
  }
  match effort_fields.get("reasoning_effort") {
    Some(String(e)) => assert_eq(e, "high")
    _ => fail("expected reasoning_effort to be emitted verbatim")
  }
}

///|
test "build_chat_request streams without stream_options" {
  let body = build_chat_request(
    OpenRouterConfig("k", model="m"),
    [user_msg("hi")],
    [],
    chat_options(),
    true,
  )
  guard body is Object(fields) else { fail("expected object body") }
  match fields.get("stream") {
    Some(value) => assert_eq(value.stringify(), "true")
    None => fail("expected stream=true for streaming requests")
  }
  // stream_options.include_usage is deprecated on OpenRouter — usage rides
  // the final chunk automatically.
  match fields.get("stream_options") {
    None => ()
    Some(_) => fail("stream_options must never be sent to OpenRouter")
  }
}

///|
test "build_chat_request serializes model, messages, tools and chat options" {
  let tool = @posoco.ToolDef::ToolDef(
    name=@posoco.ToolName::unchecked("echo"),
    description="echo back",
    input_schema=Json::object(Map::from_array([])),
    owner=@posoco.OwnerId::unchecked("test"),
    policy=@posoco.ExecutionPolicy::Sequential,
    provenance=None,
  )
  let body = build_chat_request(
    OpenRouterConfig("k", model="anthropic/claude-3.7-sonnet"),
    [user_msg("hello")],
    [tool],
    { temperature: Some(0.5), max_output_tokens: Some(256) },
    false,
  )
  guard body is Object(fields) else { fail("expected object body") }
  match fields.get("model") {
    Some(String(m)) => assert_eq(m, "anthropic/claude-3.7-sonnet")
    _ => fail("expected model field")
  }
  match fields.get("messages") {
    Some(Json::Array(arr)) => assert_true(arr.length() == 1)
    _ => fail("expected messages array")
  }
  match fields.get("tools") {
    Some(Json::Array(arr)) => assert_true(arr.length() == 1)
    _ => fail("expected tools array")
  }
  match fields.get("temperature") {
    Some(Number(t, ..)) => assert_eq(t, 0.5)
    _ => fail("expected temperature field")
  }
  match fields.get("max_tokens") {
    Some(Number(n, ..)) => assert_eq(n.to_int(), 256)
    _ => fail("expected max_tokens field")
  }
}

///|
test "encode_message assistant replays raw reasoning as reasoning_details" {
  // The encrypted-block contract: the details array must survive byte-exact
  // (same element order), so Reasoning.raw goes out untouched under the key
  // `reasoning_details`.
  let raw_details : Json = @json.parse(
    "[{\"type\":\"reasoning.encrypted\",\"data\":\"QUJD\"},{\"type\":\"reasoning.text\",\"text\":\"step two\"}]",
  ) catch {
    _ => abort("fixture JSON must parse")
  }
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("c1"),
        name: @posoco.ToolName::unchecked("read"),
        arguments: Json::empty_object(),
      },
    ],
    reasoning=Some(@posoco.Reasoning::{
      content: "thinking...",
      raw: Some(raw_details),
    }),
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let json = encode_message(msg, false)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_details") {
    Some(Json::Array(details)) =>
      assert_eq(Json::array(details).stringify(), raw_details.stringify())
    _ => fail("raw reasoning MUST replay as a reasoning_details array")
  }
  match obj.get("reasoning") {
    None => ()
    Some(_) => fail("the string fallback must not be sent while raw exists")
  }
  match obj.get("reasoning_content") {
    None => ()
    Some(_) => fail("DeepSeek's reasoning_content key must never be used")
  }
}

///|
test "encode_message assistant falls back to the reasoning string without raw" {
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{ content: "thinking...", raw: None }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let json = encode_message(msg, false)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning") {
    Some(String(r)) => assert_eq(r, "thinking...")
    _ => fail("reasoning string must be preserved on assistant messages")
  }
  match obj.get("reasoning_details") {
    None => ()
    Some(_) => fail("no reasoning_details without a raw payload")
  }
}

///|
test "encode_message tool result carries tool_call_id and outcome text" {
  let msg : @posoco.Message = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_42"),
    tool_name=@posoco.ToolName::unchecked("read_file"),
    outcome=@posoco.ToolOutcome::Success(
      content="file contents",
      structured=None,
    ),
  )
  let json = encode_message(msg, false)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("role") {
    Some(String(r)) => assert_eq(r, "tool")
    _ => fail("expected tool role")
  }
  match obj.get("tool_call_id") {
    Some(String(id)) => assert_eq(id, "call_42")
    _ => fail("tool message MUST carry tool_call_id")
  }
  match obj.get("content") {
    Some(String(c)) => assert_eq(c, "file contents")
    _ => fail("expected outcome text as content")
  }
}

///|
test "encode_message system and user roles carry plain text content" {
  let sys_json = encode_message(
    @posoco.Message::SystemMessage(content=[Text("sys")]),
    false,
  )
  guard sys_json is Object(sys_obj) else { fail("expected object") }
  match sys_obj.get("role") {
    Some(String(r)) => assert_eq(r, "system")
    _ => fail("expected system role")
  }
  let user_json = encode_message(user_msg("hello"), false)
  guard user_json is Object(user_obj) else { fail("expected object") }
  match user_obj.get("role") {
    Some(String(r)) => assert_eq(r, "user")
    _ => fail("expected user role")
  }
  match user_obj.get("content") {
    Some(String(c)) => assert_eq(c, "hello")
    _ => fail("expected concatenated text content")
  }
}

///|
test "decode_chat_response parses reasoning, reasoning_details, tool_calls and usage" {
  let fixture =
    #|{"id":"gen-1","choices":[{"message":{"role":"assistant","content":"answer","reasoning":"deep thought","reasoning_details":[{"type":"reasoning.text","text":"deep thought"},{"type":"reasoning.encrypted","data":"QUJD"}],"tool_calls":[{"id":"call_7","type":"function","function":{"name":"echo","arguments":"{\"msg\":\"hi\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":100,"completion_tokens":40,"total_tokens":140,"prompt_tokens_details":{"cached_tokens":64}}}
  let payload : Json = @json.parse(fixture) catch {
    _ => abort("fixture JSON must parse")
  }
  let completion = decode_chat_response(payload)
  assert_true(completion.message.content.length() == 1)
  match completion.message.content[0] {
    Text(s) => assert_eq(s, "answer")
    _ => fail("expected text content")
  }
  assert_eq(completion.message.finish_reason, @posoco.FinishReason::ToolCalls)
  match completion.message.reasoning {
    Some(r) => {
      assert_eq(r.content, "deep thought")
      // The whole details array lands on Reasoning.raw, element-equal and
      // order-preserving.
      guard r.raw is Some(raw) else { fail("expected raw reasoning_details") }
      match raw {
        Array(items) => {
          assert_true(items.length() == 2)
          assert_eq(
            items[0].stringify(),
            "{\"type\":\"reasoning.text\",\"text\":\"deep thought\"}",
          )
          assert_eq(
            items[1].stringify(),
            "{\"type\":\"reasoning.encrypted\",\"data\":\"QUJD\"}",
          )
        }
        _ => fail("raw must stay a JSON array")
      }
    }
    None => fail("expected reasoning to be surfaced")
  }
  assert_true(completion.message.tool_calls.length() == 1)
  let tc = completion.message.tool_calls[0]
  assert_eq(tc.call_id.to_string(), "call_7")
  assert_eq(tc.name.to_string(), "echo")
  assert_eq(tc.arguments.stringify(), "{\"msg\":\"hi\"}")
  match completion.usage {
    Some(u) => {
      assert_eq(u.input_tokens, Some(100))
      assert_eq(u.output_tokens, Some(40))
      assert_eq(u.total_tokens, Some(140))
      assert_eq(u.cached_input_tokens, Some(64))
    }
    None => fail("expected usage")
  }
}

///|
/// reasoning_details without a `reasoning` string still replays: raw keeps
/// the array and content degrades to empty (chosen over stitching display
/// text out of details — that would risk reordering encrypted blocks).
test "decode_chat_response keeps details-only reasoning with empty content" {
  let fixture =
    #|{"choices":[{"message":{"role":"assistant","content":"","reasoning_details":[{"type":"reasoning.encrypted","data":"QUJD"}]},"finish_reason":"stop"}]}
  let payload : Json = @json.parse(fixture) catch {
    _ => abort("fixture JSON must parse")
  }
  let completion = decode_chat_response(payload)
  match completion.message.reasoning {
    Some(r) => {
      assert_eq(r.content, "")
      match r.raw {
        Some(Array(items)) => assert_true(items.length() == 1)
        _ => fail("expected the details array on raw")
      }
    }
    None => fail("details-only reasoning must still surface a Reasoning")
  }
}

///|
/// Neither `reasoning` nor `reasoning_details` present → the Completion
/// carries no Reasoning at all.
test "decode_chat_response omits reasoning when both fields are absent" {
  let fixture =
    #|{"choices":[{"message":{"role":"assistant","content":"plain"},"finish_reason":"stop"}]}
  let payload : Json = @json.parse(fixture) catch {
    _ => abort("fixture JSON must parse")
  }
  let completion = decode_chat_response(payload)
  assert_true(completion.message.reasoning is None)
}

///|
test "decode_chat_response rejects a structured API error" {
  let payload = Json::object(
    Map::from_array([
      (
        "error",
        Json::object(
          Map::from_array([
            ("code", Json::number(402.0)),
            ("message", Json::string("insufficient credits")),
          ]),
        ),
      ),
    ]),
  )
  let result = Ok(decode_chat_response(payload)) catch { error => Err(error) }
  match result {
    Err(@posoco.ModelError::Transport(message)) =>
      assert_true(message.contains("stage=response.error"))
    _ => fail("expected Transport error for structured API error")
  }
}

///|
test "decode_chat_response normalizes finish_reason and rejects unknown types" {
  // Unknown but string-valued finish_reason lands in Other verbatim
  // (OpenRouter's five-value vocabulary collapses into Stop/Length/ToolCalls
  // plus Other).
  let fixture =
    #|{"choices":[{"message":{"role":"assistant","content":"x"},"finish_reason":"provider_error"}]}
  let payload : Json = @json.parse(fixture) catch {
    _ => abort("fixture JSON must parse")
  }
  let completion = decode_chat_response(payload)
  assert_eq(
    completion.message.finish_reason,
    @posoco.FinishReason::Other("provider_error"),
  )

  // A non-string finish_reason is a parse failure, not a silent Other("").
  let bad_fixture =
    #|{"choices":[{"message":{"role":"assistant","content":"x"},"finish_reason":7}]}
  let bad_payload : Json = @json.parse(bad_fixture) catch {
    _ => abort("fixture JSON must parse")
  }
  let result = Ok(decode_chat_response(bad_payload)) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=finish_reason"))
    _ => fail("expected ResponseParse for a wrong-type finish_reason")
  }
}

///|
test "decode_chat_response rejects a non-array reasoning_details" {
  let fixture =
    #|{"choices":[{"message":{"role":"assistant","content":"x","reasoning_details":"nope"},"finish_reason":"stop"}]}
  let payload : Json = @json.parse(fixture) catch {
    _ => abort("fixture JSON must parse")
  }
  let result = Ok(decode_chat_response(payload)) catch { error => Err(error) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=message.reasoning_details"))
    _ => fail("expected ResponseParse for a wrong-type reasoning_details")
  }
}

///|
test "decode_chat_response rejects missing choices" {
  let payload = Json::object(Map::from_array([]))
  let result = Ok(decode_chat_response(payload)) catch { error => Err(error) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=choices"))
    _ => fail("expected ResponseParse for missing choices")
  }
}

// ---------------------------------------------------------------------------
// http_util — status classification (error_type vocabulary, 402, 429)
// ---------------------------------------------------------------------------

///|
test "classify: 2xx statuses are not errors" {
  assert_true(
    classify_openrouter_http_status(
      "chat.http_status",
      200,
      BodyText("{}"),
      now_ms=0L,
    )
    is None,
  )
}

///|
test "classify: 402 raises Transport with payment/credits semantics" {
  let body =
    #|{"error":{"code":402,"message":"Payment required","metadata":{"error_type":"payment_required"}}}
  let err = classify_openrouter_http_status(
    "chat.http_status",
    402,
    BodyText(body),
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::Transport(msg)) else {
    fail("expected Transport")
  }
  assert_true(msg.contains("status=402"))
  assert_true(msg.contains("error_type=payment_required"))
  assert_true(msg.contains("category=payment_required"))
  assert_true(msg.contains("credits"))
}

///|
test "classify: payment_required error_type drives the payment verdict on any status" {
  let body =
    #|{"error":{"code":500,"message":"Payment required","metadata":{"error_type":"payment_required"}}}
  let err = classify_openrouter_http_status(
    "chat.http_status",
    500,
    BodyText(body),
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::Transport(msg)) else {
    fail("expected Transport")
  }
  assert_true(msg.contains("category=payment_required"))
}

///|
test "classify: 429 raises typed RateLimited, error_type preferred over bare code" {
  let body =
    #|{"error":{"code":429,"message":"Rate limit exceeded","metadata":{"error_type":"rate_limit_exceeded"}},"resets_in_seconds":756}
  let err = classify_openrouter_http_status(
    "chat.http_status",
    429,
    BodyText(body),
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  assert_eq(info.status, 429)
  // The stable vocabulary names the verdict, not the echoed numeric code.
  assert_eq(info.provider_code, Some("rate_limit_exceeded"))
  assert_eq(info.reset_at_ms, Some(756000L))
}

///|
test "classify: 429 without a body reset falls back to the Retry-After header" {
  let body =
    #|{"error":{"code":429,"message":"Rate limit exceeded"}}
  let err = classify_openrouter_http_status(
    "chat.http_status",
    429,
    BodyText(body),
    retry_after_header=Some("120"),
    now_ms=1000L,
  )
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  assert_eq(info.reset_at_ms, Some(121000L))
}

///|
test "classify: 429 falls back to X-RateLimit-Reset epoch seconds" {
  let body =
    #|{"error":{"code":429,"message":"Rate limit exceeded"}}
  let err = classify_openrouter_http_status(
    "chat.http_status",
    429,
    BodyText(body),
    rate_limit_reset_header=Some("1778839243"),
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  assert_eq(info.reset_at_ms, Some(1778839243000L))
}

///|
test "classify: plain 5xx is Transport with the body and error_type label" {
  let body =
    #|{"error":{"code":503,"message":"Provider overloaded","metadata":{"error_type":"provider_overloaded"}}}
  let err = classify_openrouter_http_status(
    "chat.http_status",
    503,
    BodyText(body),
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::Transport(msg)) else {
    fail("expected Transport")
  }
  assert_true(msg.contains("status=503"))
  assert_true(msg.contains("error_type=provider_overloaded"))
  assert_true(msg.contains("body="))
}

///|
test "classify: body metadata is dropped when unsanitizable" {
  // Free-text error_type must not become the failure's error_type label (the
  // verbatim body still rides along, as for any 400).
  let body =
    #|{"error":{"code":400,"message":"Bad request","metadata":{"error_type":"user prompt content"}}}
  let err = classify_openrouter_http_status(
    "chat.http_status",
    400,
    BodyText(body),
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::Transport(msg)) else {
    fail("expected Transport")
  }
  assert_false(msg.contains("error_type="))
}

///|
test "openrouter_epoch_seconds_ms bounds its input" {
  assert_eq(openrouter_epoch_seconds_ms("1778839243"), Some(1778839243000L))
  assert_eq(openrouter_epoch_seconds_ms(""), None)
  assert_eq(openrouter_epoch_seconds_ms("soon"), None)
  assert_eq(openrouter_epoch_seconds_ms("99999999999999999999"), None)
}

///|
test "stream termination classification stays loud without a terminal marker" {
  assert_true(classify_openrouter_stream_termination(ExplicitTerminal) is None)
  assert_true(
    classify_openrouter_stream_termination(CleanEof)
    is Some(@posoco.ModelError::ResponseParse(_)),
  )
  assert_true(
    classify_openrouter_stream_termination(TransportFailure)
    is Some(@posoco.ModelError::Transport(_)),
  )
}

// ---------------------------------------------------------------------------
// http_util — EOF tolerance and driver chunk serialization
// ---------------------------------------------------------------------------

///|
test "openrouter_eof_tolerable requires at least one tool call" {
  let state = OpenRouterStreamState()
  assert_false(openrouter_eof_tolerable(state.acc))
  // Text-only accumulation is not tolerable: a cut answer must stay loud.
  state.acc.push(@posoco.StreamChunk::TextDelta(token="partial answer"))
  assert_false(openrouter_eof_tolerable(state.acc))
}

///|
test "openrouter_eof_tolerable accepts complete tool calls" {
  let state = OpenRouterStreamState()
  let noop = fn(_ : @posoco.StreamChunk) -> Unit { () }
  let first =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":null}}]},"finish_reason":null}]}
  assert_false(process_openrouter_sse(first, state, noop))
  let cont =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"name":null,"arguments":"{\"cmd\":\"ls\"}"}}]},"finish_reason":null}]}
  assert_false(process_openrouter_sse(cont, state, noop))
  // EOF here (no finish_reason, no [DONE]): the call is complete → tolerable.
  assert_true(openrouter_eof_tolerable(state.acc))
}

///|
test "openrouter_eof_tolerable rejects arguments cut mid-stream" {
  let state = OpenRouterStreamState()
  let noop = fn(_ : @posoco.StreamChunk) -> Unit { () }
  let first =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"bash","arguments":null}}]},"finish_reason":null}]}
  assert_false(process_openrouter_sse(first, state, noop))
  // Arguments JSON truncated: unparseable — the EOF must stay a loud failure.
  let cont =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"id":null,"function":{"name":null,"arguments":"{\"cmd\":\"ls"}}]},"finish_reason":null}]}
  assert_false(process_openrouter_sse(cont, state, noop))
  assert_false(openrouter_eof_tolerable(state.acc))
}

///|
/// Provider-neutral prompt fake used to exercise OpenRouter's API-key seam.
struct OpenRouterApiKeyPrompt {
  value : String
}

///|
pub impl @oauth.AuthPromptInteraction for OpenRouterApiKeyPrompt with fn prompt(
  self : OpenRouterApiKeyPrompt,
  _request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.value
}

///|
test "OpenRouterProvider reports the fixed provider and credential ids" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  assert_eq(factory.provider_id(), "openrouter")
  assert_eq(factory.credential_id(), "openrouter")
}

///|
test "ProviderFactory::build resolves complete settings into a Ready single-slot catalog" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-or-v1-test")),
          ("model", Json::string("anthropic/claude-3.7-sonnet")),
          ("thinking_efforts", Json::array([Json::string("high")])),
          ("context_window", Json::number(200000.0)),
        ]),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      assert_eq(catalog.provider_id, "openrouter")
      assert_eq(catalog.capabilities(), [
        "chat", "streaming", "reasoning", "api_key",
      ])
      assert_eq(catalog.auth_methods(), [@llm.AuthMethod::ApiKey])
      let slot = catalog.slots()[0]
      assert_eq(slot.id, "openrouter/anthropic/claude-3.7-sonnet")
      assert_eq(slot.label, "openrouter / anthropic/claude-3.7-sonnet")
      assert_eq(slot.provider_id, "openrouter")
      assert_eq(slot.model_id, "anthropic/claude-3.7-sonnet")
      // Declared levels gain an implicit leading off; the first level is the
      // default selection.
      assert_eq(slot.thinking_efforts, ["off", "high"])
      assert_eq(slot.default_effort, Some("high"))
      assert_eq(slot.context_window, Some(200000))
      assert_true(slot.api_key is Some(_))
      assert_true(slot.rebuild_on_effort is Some(_))
      assert_true(slot.rebuild_on_api_key is Some(_))
      // The slot's port view reports the auto-compact metadata the Agent
      // builds its RunPolicy from. base_url keeps the config constructor's
      // default (no base_url key in settings); its value is covered by the
      // OpenRouterConfig tests.
      let provider_config = slot.port.provider_config()
      assert_eq(provider_config.context_window, Some(200000))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog from complete settings")
  }
}

///|
test "ProviderFactory::build exposes the plain off/on toggle when settings declare no levels" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-or-v1-test")),
          ("model", Json::string("openai/gpt-5.2")),
        ]),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.thinking_efforts, ["off", "on"])
      assert_eq(slot.default_effort, Some("off"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog without declared levels")
  }
}

///|
/// The login-first flow writes a credential before any settings exist, and
/// there is no fallback model to fabricate: a missing model must build to
/// Unconfigured so catalog refresh keeps the provider parked (and the other
/// providers alive) until settings supply one.
test "ProviderFactory::build returns Unconfigured when model is missing" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([("api_key", Json::string("sk-or-v1-test"))]),
      ),
    ),
    api_key_credential=Some(
      @oauth.ApiKeyCredential::ApiKeyCredential(secret="sk-or-v1-cred"),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Unconfigured => ()
    @llm.ProviderBuildResult::Ready(_) =>
      fail("expected Unconfigured for missing model")
  }
}

///|
test "ProviderFactory::build returns Unconfigured without api_key" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([("model", Json::string("anthropic/claude-3.7-sonnet"))]),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Unconfigured => ()
    @llm.ProviderBuildResult::Ready(_) =>
      fail("expected Unconfigured when api_key is missing")
  }
}

///|
/// api_key credential takes precedence over the api_key setting. The
/// credential store is the canonical source once /login ran.
test "ProviderFactory::build prefers api_key credential over the setting" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-from-settings")),
          ("model", Json::string("anthropic/claude-3.7-sonnet")),
        ]),
      ),
    ),
    provider_credential=Some(
      @oauth.ProviderCredential::ApiKey(
        @oauth.ApiKeyCredential::ApiKeyCredential(secret="sk-from-login"),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(_) => ()
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready when api_key credential is present")
  }
}

///|
/// OAuth credential is rejected with a typed composition error: this adapter
/// is api-key only, and a stale OAuth credential must not silently be ignored.
test "ProviderFactory::build rejects OAuth credential with typed error" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([("model", Json::string("anthropic/claude-3.7-sonnet"))]),
      ),
    ),
    provider_credential=Some(
      @oauth.ProviderCredential::OAuth(
        @oauth.Credential::Credential(
          access_token="ignored",
          refresh_token="",
          expires_at=0,
          metadata=Map::from_array([]),
        ),
      ),
    ),
  )
  let result = Ok(factory.build(source)) catch { error => Err(error) }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      assert_eq(manifest_id, "posoco_ext_openrouter")
      assert_true(detail.contains("OAuth credential is not supported"))
    }
    _ => fail("expected ManifestSchemaError for OAuth credential")
  }
}

///|
test "ProviderFactory::build rejects reserved words inside declared levels" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-or-v1-test")),
          ("model", Json::string("anthropic/claude-3.7-sonnet")),
          (
            "thinking_efforts",
            Json::array([Json::string("high"), Json::string("off")]),
          ),
        ]),
      ),
    ),
  )
  let result = Ok(factory.build(source)) catch { error => Err(error) }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      assert_eq(manifest_id, "posoco_ext_openrouter")
      assert_true(detail.contains("reserves 'off'/'on'"))
    }
    _ => fail("expected ManifestSchemaError for a reserved declared level")
  }
}

///|
/// The effort rebuild hook funnels through
/// OpenRouterConfig::with_reasoning_effort; the rebuilt slot's default_effort
/// label is the direct projection of the rebuilt thinking/reasoning_effort
/// (whose transitions the config tests pin down).
test "rebuild_on_effort switches the declared level and off through the slot" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-or-v1-test")),
          ("model", Json::string("anthropic/claude-3.7-sonnet")),
          (
            "thinking_efforts",
            Json::array([Json::string("low"), Json::string("high")]),
          ),
        ]),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.default_effort, Some("low"))
      guard slot.rebuild_on_effort is Some(rebuild) else {
        fail("declared efforts must expose a rebuild hook")
      }
      let high = rebuild("high")
      assert_eq(high.thinking_efforts, ["off", "low", "high"])
      assert_eq(high.default_effort, Some("high"))
      assert_eq(high.model_id, "anthropic/claude-3.7-sonnet")
      let off = rebuild("off")
      assert_eq(off.thinking_efforts, ["off", "low", "high"])
      assert_eq(off.default_effort, Some("off"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with declared levels")
  }
}

///|
async test "ApiKeyFactory::login validates and returns an opaque credential" {
  let factory_impl = OpenRouterApiKeyFactory()
  let api : &@llm.ApiKeyFactory = factory_impl
  assert_eq(api.provider_id(), "openrouter")
  assert_eq(api.credential_id(), "openrouter")
  let prompt_impl = OpenRouterApiKeyPrompt::{ value: "sk-or-secret" }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let credential = api.login(prompt)
  assert_eq(credential.secret, "sk-or-secret")
}

///|
async test "ApiKeyFactory::login rejects an empty secret" {
  let factory_impl = OpenRouterApiKeyFactory()
  let api : &@llm.ApiKeyFactory = factory_impl
  let prompt_impl = OpenRouterApiKeyPrompt::{ value: "" }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let result = Ok(api.login(prompt)) catch { error => Err(error) }
  match result {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("must not be empty"))
    _ => fail("expected empty OpenRouter API key to fail")
  }
}

///|
/// Discovery metadata drives the picker surface: level-bearing reasoning
/// models expose their declared efforts with the endpoint's default selected,
/// toggle models expose off/on, and plain models expose nothing.
test "parse_openrouter_models maps reasoning metadata onto model info" {
  let payload : Json = Json::object(
    Map::from_array([
      (
        "data",
        Json::array([
          Json::object(
            Map::from_array([
              ("id", Json::string("anthropic/claude-sonnet-4.5")),
              ("context_length", Json::number(200000.0)),
              (
                "reasoning",
                Json::object(
                  Map::from_array([
                    (
                      "supported_efforts",
                      Json::array([
                        Json::string("low"),
                        Json::string("medium"),
                        Json::string("high"),
                      ]),
                    ),
                    ("default_effort", Json::string("high")),
                  ]),
                ),
              ),
            ]),
          ),
          Json::object(
            Map::from_array([
              ("id", Json::string("openai/gpt-5.1")),
              (
                "supported_parameters",
                Json::array([Json::string("tools"), Json::string("reasoning")]),
              ),
            ]),
          ),
          Json::object(
            Map::from_array([
              ("id", Json::string("meta-llama/llama-4-scout")),
              ("context_length", Json::number(128000.0)),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let models = parse_openrouter_models(payload)
  assert_eq(models.length(), 3)
  assert_eq(models[0].id, "anthropic/claude-sonnet-4.5")
  assert_eq(models[0].context_length, Some(200000))
  assert_eq(models[0].supported_efforts, ["low", "medium", "high"])
  assert_eq(models[0].default_effort, Some("high"))
  assert_true(models[0].reasoning_supported)
  // supported_parameters-only reasoning is the off/on toggle, default on.
  assert_true(models[1].reasoning_supported)
  assert_true(models[1].default_enabled)
  assert_eq(models[1].supported_efforts.length(), 0)
  // A model without metadata is plain chat.
  assert_false(models[2].reasoning_supported)
  assert_eq(models[2].context_length, Some(128000))
}

///|
/// The catalog builder pins the configured model first, preserves endpoint
/// order for the rest, and bakes each model's metadata into its slot.
test "openrouter_model_catalog expands discovery into ordered slots" {
  let factory : &@llm.ApiKeyFactory = OpenRouterApiKeyFactory()
  let models = [
    {
      id: "a/first",
      context_length: Some(1000),
      reasoning_supported: true,
      supported_efforts: ["low", "high"],
      default_effort: Some("high"),
      default_enabled: true,
      supports_images: false,
    },
    {
      id: "b/plain",
      context_length: None,
      reasoning_supported: false,
      supported_efforts: [],
      default_effort: None,
      default_enabled: false,
      supports_images: false,
    },
  ]
  let catalog = openrouter_model_catalog(
    "sk-or-v1-test", "https://openrouter.ai/api/v1", models, "b/plain", factory,
  )
  let slots = catalog.slots()
  assert_eq(slots.length(), 2)
  // Preferred pinned first even though the endpoint listed it second.
  assert_eq(slots[0].model_id, "b/plain")
  assert_eq(slots[0].id, "openrouter/b/plain")
  assert_eq(slots[0].context_window, None)
  // Even a metadata-plain model keeps the off/on toggle: it is the escape
  // hatch when a model's reasoning metadata has not landed yet, and a model
  // without reasoning support silently ignores include_reasoning.
  assert_eq(slots[0].thinking_efforts, ["off", "on"])
  // Effort model: picker prepends "off", default label is the metadata default.
  assert_eq(slots[1].model_id, "a/first")
  assert_eq(slots[1].context_window, Some(1000))
  assert_eq(slots[1].thinking_efforts, ["off", "low", "high"])
  assert_eq(slots[1].default_effort, Some("high"))
}

///|
/// The static build path expands host-cached discovery records offline, so a
/// restart after login+refresh announces the full catalog without settings.
test "ProviderFactory::build expands cached discovery records without settings" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  let cached : Json = Json::array([
    Json::object(
      Map::from_array([
        ("model_id", Json::string("anthropic/claude-sonnet-4.5")),
        (
          "thinking_efforts",
          Json::array([
            Json::string("off"),
            Json::string("low"),
            Json::string("high"),
          ]),
        ),
        ("default_effort", Json::string("high")),
        ("context_window", Json::number(200000.0)),
      ]),
    ),
    Json::object(
      Map::from_array([
        ("model_id", Json::string("meta-llama/llama-4-scout")),
        ("thinking_efforts", Json::array([])),
        ("default_effort", Json::null()),
        ("context_window", Json::null()),
      ]),
    ),
  ])
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=None,
    api_key_credential=Some(
      @oauth.ApiKeyCredential::ApiKeyCredential(secret="sk-or-v1-cred"),
    ),
    cached_models=Some(cached),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slots = catalog.slots()
      assert_eq(slots.length(), 2)
      assert_eq(slots[0].model_id, "anthropic/claude-sonnet-4.5")
      assert_eq(slots[0].thinking_efforts, ["off", "low", "high"])
      assert_eq(slots[0].default_effort, Some("high"))
      assert_eq(slots[0].context_window, Some(200000))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("cached records must expand to a Ready catalog")
  }
}

///|
/// A malformed cache record degrades to the static path instead of failing
/// composition — the cache is derived data.
test "ProviderFactory::build degrades on malformed cache records" {
  let provider = OpenRouterProvider()
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-or-v1-test")),
          ("model", Json::string("anthropic/claude-sonnet-4.5")),
        ]),
      ),
    ),
    cached_models=Some(Json::array([Json::string("not-an-object")])),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) =>
      assert_eq(catalog.slots().length(), 1)
    @llm.ProviderBuildResult::Unconfigured =>
      fail("settings model must still build when the cache is malformed")
  }
}

///|
/// Vision capability three-state: discovery parses
/// `architecture.input_modalities` onto the model info, the slot advertises
/// `image_in` only for image-capable models, and the encoder sends typed
/// parts or an explicit placeholder accordingly.
test "vision capability flows from discovery to slot to encoder" {
  // 1. Discovery: architecture.input_modalities carries the modality vector.
  let payload : Json = @json.parse(
    (
      #|{
      #|  "data": [
      #|    { "id": "vendor/vision",
      #|      "architecture": { "input_modalities": ["text", "image"] } },
      #|    { "id": "vendor/text",
      #|      "architecture": { "input_modalities": ["text"] } },
      #|    { "id": "vendor/legacy" }
      #|  ]
      #|}
    ),
  ) catch {
    _ => fail("fixture parse failed")
  }
  let models = parse_openrouter_models(payload)
  inspect(models[0].supports_images, content="true")
  inspect(models[1].supports_images, content="false")
  inspect(models[2].supports_images, content="false")
  // 2. Slot capability: only the image model advertises image_in.
  let factory : &@llm.ApiKeyFactory = OpenRouterApiKeyFactory()
  let catalog = openrouter_model_catalog(
    "key", "https://openrouter.ai/api/v1", models, "", factory,
  )
  let vision_caps : Array[String] = []
  let text_caps : Array[String] = []
  for slot in catalog.slots() {
    match slot.id {
      "openrouter/vendor/vision" => vision_caps.append(slot.capabilities.copy())
      "openrouter/vendor/text" => text_caps.append(slot.capabilities.copy())
      _ => ()
    }
  }
  assert_true(vision_caps.contains("image_in"))
  assert_false(text_caps.contains("image_in"))
  // 3. Encoder: parts when the config supports images, placeholder otherwise.
  let img_msg : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("look"),
    @posoco.Content::Image(media_type="image/png", data="aW1n"),
  ])
  guard encode_message(img_msg, true) is Object(v) else {
    fail("expected object")
  }
  guard v.get("content") is Some(Array([_, _])) else {
    fail("expected two content parts")
  }
  guard encode_message(img_msg, false) is Object(t) else {
    fail("expected object")
  }
  guard t.get("content") is Some(String(downgraded)) else {
    fail("expected string content")
  }
  assert_true(downgraded.contains("look"))
  assert_true(downgraded.contains("[Attached image/png"))
}
