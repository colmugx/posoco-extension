///|
/// Blackbox tests for posoco-ext-openai-compatible.
///
/// These exercise the pure config/build/encode/decode/api-key-seam logic
/// without any network calls. Streaming and live HTTP behavior are validated
/// through the host (cetas-js) integration surface.

///|
fn user_msg(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
fn chat_options() -> @posoco.ChatOptions {
  { temperature: None, max_output_tokens: None, }
}

///|
/// Provider-neutral prompt fake used to exercise the API-key seam.
struct OaiCompatApiKeyPrompt {
  value : String
}

///|
pub impl @oauth.AuthPromptInteraction for OaiCompatApiKeyPrompt with fn prompt(
  self : OaiCompatApiKeyPrompt,
  _request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.value
}

///|
test "OpenAICompatibleConfig records required and optional fields" {
  let config = OpenAICompatibleConfig(
    "sk-test",
    base_url="https://example.com/v1",
    model="qwen-plus",
  )
  assert_eq(config.api_key, "sk-test")
  assert_eq(config.base_url, "https://example.com/v1")
  assert_eq(config.model, "qwen-plus")
  assert_eq(config.endpoint_prefix, "")
  assert_false(config.thinking)
  assert_eq(config.reasoning_effort, None)
}

///|
test "OpenAICompatibleConfig carries optional fields" {
  let config = OpenAICompatibleConfig(
    "sk-test",
    base_url="https://example.com",
    model="qwen-plus",
    endpoint_prefix="/v1",
    thinking=true,
    reasoning_effort=Some("medium"),
  )
  assert_eq(config.endpoint_prefix, "/v1")
  assert_true(config.thinking)
  assert_eq(config.reasoning_effort, Some("medium"))
}

///|
test "OpenAICompatibleProvider scopes to the given provider id" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  assert_eq(factory.provider_id(), "qwen")
  assert_eq(factory.credential_id(), "qwen")
}

///|
/// Build with no credential and no api_key setting → Unconfigured (the host
/// shows no slot rather than failing composition).
test "ProviderFactory::build returns Unconfigured without api_key" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("base_url", Json::string("https://example.com/v1")),
          ("model", Json::string("qwen-plus")),
        ]),
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
test "ProviderFactory::build returns Unconfigured without base_url" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-test")),
          ("model", Json::string("qwen-plus")),
        ]),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Unconfigured => ()
    @llm.ProviderBuildResult::Ready(_) =>
      fail("expected Unconfigured when base_url is missing")
  }
}

///|
test "ProviderFactory::build returns Unconfigured without model" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-test")),
          ("base_url", Json::string("https://example.com/v1")),
        ]),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Unconfigured => ()
    @llm.ProviderBuildResult::Ready(_) =>
      fail("expected Unconfigured when model is missing")
  }
}

///|
test "ProviderFactory::build with api_key setting produces a Ready catalog" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-test")),
          (
            "base_url",
            Json::string("https://dashscope.aliyuncs.com/compatible-mode/v1"),
          ),
          ("model", Json::string("qwen-plus")),
          ("reasoning_effort", Json::string("medium")),
        ]),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      assert_eq(catalog.provider_id, "qwen")
      let slots = catalog.slots()
      assert_true(slots.length() == 1)
      let slot = slots[0]
      assert_eq(slot.provider_id, "qwen")
      assert_eq(slot.model_id, "qwen-plus")
      // Slot id embeds both provider and model so /model lists it distinctly.
      assert_eq(slot.id, "qwen/qwen-plus")
      assert_true(slot.capabilities.contains("chat"))
      assert_true(slot.capabilities.contains("streaming"))
      assert_true(slot.capabilities.contains("api_key"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
/// api_key credential takes precedence over the api_key setting, mirroring
/// DeepSeek. The credential store is the canonical source once /login ran.
test "ProviderFactory::build prefers api_key credential over the setting" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-from-settings")),
          ("base_url", Json::string("https://example.com/v1")),
          ("model", Json::string("qwen-plus")),
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
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("base_url", Json::string("https://example.com/v1")),
          ("model", Json::string("qwen-plus")),
        ]),
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
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("OAuth credential is not supported"))
    _ => fail("expected ManifestSchemaError for OAuth credential")
  }
}

///|
async test "ApiKeyFactory::login validates and returns an opaque credential" {
  let provider = OpenAICompatibleProvider("qwen")
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = OaiCompatApiKeyPrompt::{ value: "sk-via-login", }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let credential = api.login(prompt)
  assert_eq(credential.secret, "sk-via-login")
}

///|
async test "ApiKeyFactory::login rejects an empty secret" {
  let provider = OpenAICompatibleProvider("qwen")
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = OaiCompatApiKeyPrompt::{ value: "", }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let result = Ok(api.login(prompt)) catch { error => Err(error) }
  match result {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("must not be empty"))
    _ => fail("expected empty API key to fail")
  }
}

///|
/// Build a request body and assert the reasoning wire contract: thinking off
/// omits `thinking`/`reasoning_effort` entirely; thinking on sends the object
/// form `thinking: {"type": "enabled"}` (never a bare boolean); a selected
/// level additionally sends the top-level `reasoning_effort` verbatim.
test "build_chat_request omits thinking when off and uses the object form when on" {
  let opts = chat_options()
  let with_effort = build_chat_request(
    [user_msg("hi")],
    [],
    opts,
    "qwen-plus",
    false,
    true,
    Some("low"),
    false,
  )
  guard with_effort is Object(with_fields) else {
    fail("expected request to be an object")
  }
  match with_fields.get("thinking") {
    Some(Json::Object(thinking)) =>
      match thinking.get("type") {
        Some(Json::String("enabled")) => ()
        _ => fail("expected thinking object with type=enabled")
      }
    _ => fail("expected the thinking object when a level is selected")
  }
  match with_fields.get("reasoning_effort") {
    Some(Json::String(value)) => assert_eq(value, "low")
    _ => fail("expected reasoning_effort to be emitted when a level is set")
  }

  let toggle_on = build_chat_request(
    [user_msg("hi")],
    [],
    opts,
    "qwen-plus",
    false,
    true,
    None,
    false,
  )
  guard toggle_on is Object(on_fields) else {
    fail("expected request to be an object")
  }
  match on_fields.get("thinking") {
    Some(Json::Object(thinking)) =>
      match thinking.get("type") {
        Some(Json::String("enabled")) => ()
        _ => fail("expected thinking object with type=enabled")
      }
    _ => fail("expected the thinking object in plain toggle mode")
  }
  match on_fields.get("reasoning_effort") {
    None => ()
    Some(_) => fail("reasoning_effort must be omitted without a level")
  }

  let toggle_off = build_chat_request(
    [user_msg("hi")],
    [],
    opts,
    "qwen-plus",
    false,
    false,
    None,
    false,
  )
  guard toggle_off is Object(off_fields) else {
    fail("expected request to be an object")
  }
  match off_fields.get("thinking") {
    None => ()
    Some(_) => fail("thinking must be omitted entirely when off")
  }
  match off_fields.get("reasoning_effort") {
    None => ()
    Some(_) => fail("reasoning_effort must be omitted when off")
  }
}

///|
/// The HTTP error message embeds the provider's UTF-8 error body verbatim —
/// a 400 must say why it is a 400 — and caps runaway bodies.
test "format_oai_compat_http_error embeds the provider body" {
  let message = format_oai_compat_http_error(
    "chat_stream.http_status",
    400,
    BodyText("{\"error\":{\"message\":\"thinking must be an object\"}}"),
  )
  assert_true(
    message.contains(
      "openai-compatible HTTP error (stage=chat_stream.http_status, status=400, body=",
    ),
  )
  assert_true(message.contains("thinking must be an object"))

  let huge = String::make(oai_compat_error_body_cap + 100, 'x')
  let capped = format_oai_compat_http_error(
    "chat.http_status",
    502,
    BodyText(huge),
  )
  assert_true(capped.contains("...(truncated, body_chars=2148)"))
  // The embedded body is capped; only formatting overhead rides along.
  assert_true(capped.length() <= huge.length() + 100)
}

///|
test "build_chat_request serializes model and messages" {
  let opts = chat_options()
  let body = build_chat_request(
    [user_msg("hello")],
    [],
    opts,
    "qwen-plus",
    false,
    false,
    None,
    false,
  )
  guard body is Object(fields) else { fail("expected object body") }
  match fields.get("model") {
    Some(Json::String(m)) => assert_eq(m, "qwen-plus")
    _ => fail("expected model field")
  }
  match fields.get("messages") {
    Some(Json::Array(arr)) => assert_true(arr.length() == 1)
    _ => fail("expected messages array")
  }
}

///|
test "build_chat_request carries tools and stream options" {
  let opts = chat_options()
  let tool = @posoco.ToolDef::ToolDef(
    name=@posoco.ToolName::unchecked("echo"),
    description="echo back",
    input_schema=Json::object(Map::from_array([])),
    owner=@posoco.OwnerId::unchecked("test"),
    policy=@posoco.ExecutionPolicy::Sequential,
    provenance=None,
  )
  let body = build_chat_request(
    [user_msg("hi")],
    [tool],
    opts,
    "m",
    true,
    false,
    None,
    false,
  )
  guard body is Object(fields) else { fail("expected object body") }
  match fields.get("tools") {
    Some(Json::Array(arr)) => assert_true(arr.length() == 1)
    _ => fail("expected tools array")
  }
  match fields.get("stream") {
    Some(value) => assert_eq(value.stringify(), "true")
    None => fail("expected stream field")
  }
  match fields.get("stream_options") {
    Some(Json::Object(_)) => ()
    _ => fail("expected stream_options for usage accounting")
  }
}

///|
/// Tool-role messages MUST carry `tool_call_id` — the correlation key for the
/// assistant tool_call they answer. OpenAI requires it; zen's upstream drops
/// the request without it (curl-verified 2026-08).
test "encode_message_tool_result_carries_tool_call_id" {
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
/// Thinking-mode upstreams (DeepSeek behind opencode-zen) 400 unless the
/// assistant message that carried tool_calls resends `reasoning_content`.
test "encode_message_reasoning_resent_with_tool_calls" {
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
      content: "thinking about this...",
      raw: None,
    }),
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let json = encode_message(msg, false)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    Some(String(r)) => assert_eq(r, "thinking about this...")
    _ => fail("reasoning_content MUST be present when tool_calls exist")
  }
}

///|
/// Without tool_calls, `reasoning_content` is optional and wasteful (pollutes
/// prefix cache) — omit it even when present.
test "encode_message_reasoning_preserved_without_tool_calls" {
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{ content: "thinking...", raw: None, }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let json = encode_message(msg, false)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    Some(String(r)) => assert_eq(r, "thinking...")
    _ => fail("reasoning_content must be preserved on assistant messages")
  }
}

///|
/// Decode a standard Chat Completions response. reasoning_content is optional;
/// when absent the Completion carries no reasoning.
test "decode_chat_response parses a plain text response" {
  let payload = Json::object(
    Map::from_array([
      (
        "choices",
        Json::array([
          Json::object(
            Map::from_array([
              (
                "message",
                Json::object(
                  Map::from_array([
                    ("role", Json::string("assistant")),
                    ("content", Json::string("hi there")),
                  ]),
                ),
              ),
              ("finish_reason", Json::string("stop")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let completion = decode_chat_response(payload)
  assert_true(completion.message.content.length() == 1)
  match completion.message.content[0] {
    Text(s) => assert_eq(s, "hi there")
    _ => fail("expected text content")
  }
  assert_true(completion.message.reasoning is None)
  assert_eq(completion.message.finish_reason, @posoco.FinishReason::Stop)
}

///|
test "decode_chat_response surfaces reasoning_content when present" {
  let payload = Json::object(
    Map::from_array([
      (
        "choices",
        Json::array([
          Json::object(
            Map::from_array([
              (
                "message",
                Json::object(
                  Map::from_array([
                    ("role", Json::string("assistant")),
                    ("content", Json::string("answer")),
                    ("reasoning_content", Json::string("thinking...")),
                  ]),
                ),
              ),
              ("finish_reason", Json::string("stop")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let completion = decode_chat_response(payload)
  match completion.message.reasoning {
    Some(r) => assert_eq(r.content, "thinking...")
    None => fail("expected reasoning to be surfaced")
  }
}

///|
test "decode_chat_response parses tool_calls" {
  let payload = Json::object(
    Map::from_array([
      (
        "choices",
        Json::array([
          Json::object(
            Map::from_array([
              (
                "message",
                Json::object(
                  Map::from_array([
                    ("role", Json::string("assistant")),
                    ("content", Json::string("")),
                    (
                      "tool_calls",
                      Json::array([
                        Json::object(
                          Map::from_array([
                            ("id", Json::string("call_1")),
                            (
                              "function",
                              Json::object(
                                Map::from_array([
                                  ("name", Json::string("echo")),
                                  (
                                    "arguments",
                                    Json::string("{\"msg\":\"hi\"}"),
                                  ),
                                ]),
                              ),
                            ),
                          ]),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
              ("finish_reason", Json::string("tool_calls")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let completion = decode_chat_response(payload)
  assert_true(completion.message.tool_calls.length() == 1)
  let tc = completion.message.tool_calls[0]
  assert_eq(tc.call_id.to_string(), "call_1")
  assert_eq(tc.name.to_string(), "echo")
  assert_eq(completion.message.finish_reason, @posoco.FinishReason::ToolCalls)
}

///|
test "decode_chat_response extracts usage when present" {
  let payload = Json::object(
    Map::from_array([
      (
        "choices",
        Json::array([
          Json::object(
            Map::from_array([
              (
                "message",
                Json::object(Map::from_array([("content", Json::string("ok"))])),
              ),
              ("finish_reason", Json::string("stop")),
            ]),
          ),
        ]),
      ),
      (
        "usage",
        Json::object(
          Map::from_array([
            ("prompt_tokens", Json::number(10.0)),
            ("completion_tokens", Json::number(5.0)),
            ("total_tokens", Json::number(15.0)),
          ]),
        ),
      ),
    ]),
  )
  let completion = decode_chat_response(payload)
  match completion.usage {
    Some(u) => {
      assert_eq(u.input_tokens, Some(10))
      assert_eq(u.output_tokens, Some(5))
      assert_eq(u.total_tokens, Some(15))
    }
    None => fail("expected usage")
  }
}

///|
test "decode_chat_response rejects a missing choices field" {
  let payload = Json::object(Map::from_array([]))
  let result = Ok(decode_chat_response(payload)) catch { error => Err(error) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=choices"))
    _ => fail("expected ResponseParse for missing choices")
  }
}

///|
test "decode_chat_response rejects a structured API error" {
  let payload = Json::object(
    Map::from_array([("error", Json::object(Map::from_array([])))]),
  )
  let result = Ok(decode_chat_response(payload)) catch { error => Err(error) }
  match result {
    Err(@posoco.ModelError::Transport(_)) => ()
    _ => fail("expected Transport error for structured API error")
  }
}

///|
/// Helper: a fully-configured settings source carrying a reasoning_efforts
/// declaration, so effort-selector tests share one fixture.
fn effort_settings_source(
  reasoning_effort : String,
  reasoning_efforts : Json,
) -> @llm.ProviderConfigSource {
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-test")),
          ("base_url", Json::string("https://example.com/v1")),
          ("model", Json::string("qwen-plus")),
          ("reasoning_effort", Json::string(reasoning_effort)),
          ("reasoning_efforts", reasoning_efforts),
        ]),
      ),
    ),
  )
}

///|
test "ProviderFactory::build advertises declared efforts with an implicit off and the custom display group" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = effort_settings_source(
    "high",
    Json::array([Json::string("low"), Json::string("high")]),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.thinking_efforts, ["off", "low", "high"])
      assert_eq(slot.default_effort, Some("high"))
      assert_eq(slot.display_group, Some("custom"))
      assert_true(slot.rebuild_on_effort is Some(_))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
test "rebuild_on_effort off rebuilds the slot without a wire effort" {
  let config = OpenAICompatibleConfig(
    "sk-test",
    base_url="https://example.com/v1",
    model="qwen-plus",
    thinking=true,
    reasoning_effort=Some("high"),
    thinking_efforts=["low", "high"],
  )
  let port = OpenAICompatibleModelPort("qwen", config)
  let catalog = port.model_catalog()
  let slot = catalog.slots()[0]
  guard slot.rebuild_on_effort is Some(rebuild) else {
    fail("declared efforts must expose a rebuild hook")
  }
  let rebuilt = rebuild("off")
  assert_eq(rebuilt.thinking_efforts, ["off", "low", "high"])
  assert_eq(rebuilt.default_effort, Some("off"))
  assert_eq(rebuilt.display_group, Some("custom"))
}

///|
test "OpenAICompatibleConfig::with_reasoning_effort maps the selector vocabulary" {
  let config = OpenAICompatibleConfig(
    "sk-test",
    base_url="https://example.com/v1",
    model="qwen-plus",
    thinking=true,
    reasoning_effort=Some("high"),
    thinking_efforts=["low", "high"],
  )
  let off = config.with_reasoning_effort("off")
  assert_false(off.thinking)
  assert_eq(off.reasoning_effort, None)
  let low = config.with_reasoning_effort("low")
  assert_true(low.thinking)
  assert_eq(low.reasoning_effort, Some("low"))
  let invalid = Ok(config.with_reasoning_effort("max")) catch {
    err => Err(err)
  }
  match invalid {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("unsupported reasoning effort"))
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
  let config = OpenAICompatibleConfig(
    "sk-test",
    base_url="https://example.com/v1",
    model="qwen-plus",
  )
  let on = config.with_reasoning_effort("on")
  assert_true(on.thinking)
  assert_eq(on.reasoning_effort, None)
  let off = on.with_reasoning_effort("off")
  assert_false(off.thinking)
  assert_eq(off.reasoning_effort, None)
}

///|
test "ProviderFactory::build rejects a singular effort outside the declared list" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = effort_settings_source(
    "max",
    Json::array([Json::string("low"), Json::string("high")]),
  )
  let result = Ok(factory.build(source)) catch { err => Err(err) }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("reasoning_effort"))
    _ =>
      fail("a singular effort outside reasoning_efforts must fail composition")
  }
}

///|
test "ProviderFactory::build rejects malformed reasoning_efforts" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let not_array = Ok(
    factory.build(effort_settings_source("high", Json::string("low,high"))),
  ) catch {
    err => Err(err)
  }
  match not_array {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("reasoning_efforts"))
    _ => fail("a non-array reasoning_efforts must fail composition")
  }
  let empty_entry = Ok(
    factory.build(
      effort_settings_source(
        "high",
        Json::array([Json::string("low"), Json::string("")]),
      ),
    ),
  ) catch {
    err => Err(err)
  }
  match empty_entry {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("reasoning_efforts"))
    _ => fail("an empty effort entry must fail composition")
  }
}

///|
test "process_oai_compat_sse tolerates explicit nulls in tool-call continuation chunks" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let on_chunk = fn(chunk : @posoco.StreamChunk) -> Unit { chunks.push(chunk) }
  // First delta carries the id and name; arguments start as explicit null.
  let first = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"echo\",\"arguments\":null}}]},\"finish_reason\":null}]}"
  assert_false(process_oai_compat_sse(first, acc, on_chunk))
  // Continuation delta: some compatible servers serialize absent fields as
  // explicit null instead of omitting the keys.
  let cont = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":null,\"function\":{\"name\":null,\"arguments\":\"{\\\"text\\\":\\\"hi\\\"}\"}}]},\"finish_reason\":null}]}"
  assert_false(process_oai_compat_sse(cont, acc, on_chunk))
  let last = "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"
  assert_true(process_oai_compat_sse(last, acc, on_chunk))
  let completion = acc.to_completion()
  assert_true(completion.message.tool_calls.length() == 1)
  let tc = completion.message.tool_calls[0]
  assert_eq(tc.call_id.to_string(), "call_1")
  assert_eq(tc.name.to_string(), "echo")
  assert_eq(tc.arguments.stringify(), "{\"text\":\"hi\"}")
}

///|
/// Helper: a fully-configured settings source without a `reasoning_efforts`
/// declaration, optionally carrying a fixed singular `reasoning_effort`.
fn undeclared_effort_settings_source(
  reasoning_effort? : String = "",
  reasoning_efforts? : Json = Json::null(),
) -> @llm.ProviderConfigSource {
  let fields : Array[(String, Json)] = [
    ("api_key", Json::string("sk-test")),
    ("base_url", Json::string("https://example.com/v1")),
    ("model", Json::string("qwen-plus")),
  ]
  if reasoning_effort != "" {
    fields.push(("reasoning_effort", Json::string(reasoning_effort)))
  }
  match reasoning_efforts {
    Json::Null => ()
    declared => fields.push(("reasoning_efforts", declared))
  }
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object(Map::from_array(fields.copy()))),
  )
}

///|
test "ProviderFactory::build exposes the plain off/on toggle when settings declare no levels" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  match factory.build(undeclared_effort_settings_source()) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.thinking_efforts, ["off", "on"])
      assert_eq(slot.default_effort, Some("off"))
      assert_true(slot.rebuild_on_effort is Some(_))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
test "an explicit empty reasoning_efforts array still exposes the toggle" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  match
    factory.build(
      undeclared_effort_settings_source(reasoning_efforts=Json::array([])),
    ) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.thinking_efforts, ["off", "on"])
      assert_eq(slot.default_effort, Some("off"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
test "an array reasoning_effort declares the selectable levels verbatim" {
  let provider = OpenAICompatibleProvider("mtplx")
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-test")),
          ("base_url", Json::string("http://127.0.0.1:8000/v1")),
          ("model", Json::string("mtplx-qwen38-27b")),
          ("reasoning_effort", Json::array([Json::string("low")])),
        ]),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      // off is auto-prepended; each declared value surfaces as key and value.
      assert_eq(slot.thinking_efforts, ["off", "low"])
      assert_eq(slot.default_effort, Some("low"))
      guard slot.rebuild_on_effort is Some(rebuild) else {
        fail("declared levels must expose a rebuild hook")
      }
      // Selecting the level enables thinking and sends the value verbatim.
      let rebuilt = rebuild("low")
      assert_eq(rebuilt.default_effort, Some("low"))
      let off = rebuild("off")
      assert_eq(off.default_effort, Some("off"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
test "a multi-level reasoning_effort array keeps every value selectable" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-test")),
          ("base_url", Json::string("https://example.com/v1")),
          ("model", Json::string("qwen-plus")),
          (
            "reasoning_effort",
            Json::array([Json::string("low"), Json::string("max")]),
          ),
        ]),
      ),
    ),
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.thinking_efforts, ["off", "low", "max"])
      assert_eq(slot.default_effort, Some("low"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
test "a fixed singular reasoning_effort outside the convention stays selectable" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  match
    factory.build(undeclared_effort_settings_source(reasoning_effort="deep")) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.thinking_efforts, ["off", "deep"])
      assert_eq(slot.default_effort, Some("deep"))
      guard slot.rebuild_on_effort is Some(rebuild) else {
        fail("the fixed effort must keep the slot rebuildable")
      }
      assert_eq(rebuild("deep").default_effort, Some("deep"))
      assert_eq(rebuild("off").default_effort, Some("off"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
test "a legacy toggle-word reasoning_effort sets the on/off default" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  match
    factory.build(undeclared_effort_settings_source(reasoning_effort="on")) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.thinking_efforts, ["off", "on"])
      assert_eq(slot.default_effort, Some("on"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
test "ProviderFactory::build rejects reserved words inside declared levels" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let reserved = Ok(
    factory.build(
      undeclared_effort_settings_source(
        reasoning_efforts=Json::array([Json::string("low"), Json::string("on")]),
      ),
    ),
  ) catch {
    err => Err(err)
  }
  match reserved {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("reserves"))
    _ => fail("'on' inside a declared level list must fail composition")
  }
}

///|
test "ProviderFactory::build rejects duplicate declared levels" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let duplicate = Ok(
    factory.build(
      undeclared_effort_settings_source(
        reasoning_efforts=Json::array([Json::string("low"), Json::string("low")]),
      ),
    ),
  ) catch {
    err => Err(err)
  }
  match duplicate {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("unique"))
    _ => fail("duplicate declared levels must fail composition")
  }
}

///|
test "ProviderFactory::build rejects conflicting singular and plural level lists" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let conflicting = Ok(
    factory.build(
      @llm.ProviderConfigSource::ProviderConfigSource(
        settings=Some(
          Json::object(
            Map::from_array([
              ("api_key", Json::string("sk-test")),
              ("base_url", Json::string("https://example.com/v1")),
              ("model", Json::string("qwen-plus")),
              ("reasoning_effort", Json::array([Json::string("low")])),
              ("reasoning_efforts", Json::array([Json::string("high")])),
            ]),
          ),
        ),
      ),
    ),
  ) catch {
    err => Err(err)
  }
  match conflicting {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("different level lists"))
    _ => fail("conflicting level lists must fail composition")
  }
}

///|
test "ProviderFactory::build rejects a non-string non-array reasoning_effort" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let bad = Ok(
    factory.build(
      @llm.ProviderConfigSource::ProviderConfigSource(
        settings=Some(
          Json::object(
            Map::from_array([
              ("api_key", Json::string("sk-test")),
              ("base_url", Json::string("https://example.com/v1")),
              ("model", Json::string("qwen-plus")),
              ("reasoning_effort", Json::number(3)),
            ]),
          ),
        ),
      ),
    ),
  ) catch {
    err => Err(err)
  }
  match bad {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("array of levels or a single string"))
    _ => fail("a numeric reasoning_effort must fail composition")
  }
}

///|
test "decode_chat_response extracts cached tokens via prompt_tokens_details" {
  let payload = Json::object(
    Map::from_array([
      (
        "choices",
        Json::array([
          Json::object(
            Map::from_array([
              (
                "message",
                Json::object(Map::from_array([("content", Json::string("ok"))])),
              ),
              ("finish_reason", Json::string("stop")),
            ]),
          ),
        ]),
      ),
      (
        "usage",
        Json::object(
          Map::from_array([
            ("prompt_tokens", Json::number(1200.0)),
            ("completion_tokens", Json::number(5.0)),
            ("total_tokens", Json::number(1205.0)),
            (
              "prompt_tokens_details",
              Json::object(
                Map::from_array([("cached_tokens", Json::number(1000.0))]),
              ),
            ),
          ]),
        ),
      ),
    ]),
  )
  let completion = decode_chat_response(payload)
  match completion.usage {
    Some(u) => {
      assert_eq(u.input_tokens, Some(1200))
      assert_eq(u.cached_input_tokens, Some(1000))
    }
    None => fail("expected usage")
  }
}

///|
test "classify: 429 raises typed RateLimited with the stated reset" {
  let body = "{\"error\":{\"type\":\"usage_limit_reached\",\"message\":\"The usage limit has been reached\",\"resets_at\":1778839243,\"resets_in_seconds\":756}}"
  let err = classify_oai_compat_http_status(
    "chat.http_status",
    429,
    BodyText(body),
    now_ms=0L,
  )
  guard err is Some(@posoco.ModelError::RateLimited(info)) else {
    fail("expected RateLimited")
  }
  assert_eq(info.provider_code, Some("usage_limit_reached"))
  assert_eq(info.reset_at_ms, Some(756000L))
  let other = classify_oai_compat_http_status(
    "chat.http_status",
    500,
    BodyText("boom"),
    now_ms=0L,
  )
  assert_true(other is Some(@posoco.ModelError::Transport(_)))
}

///|
test "oai_compat_eof_tolerable requires at least one tool call" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  assert_false(oai_compat_eof_tolerable(acc))
  // Text-only accumulation is not tolerable: a cut answer must stay loud.
  acc.push(@posoco.StreamChunk::TextDelta(token="partial answer"))
  assert_false(oai_compat_eof_tolerable(acc))
}

///|
test "oai_compat_eof_tolerable accepts complete tool calls" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let noop = fn(_ : @posoco.StreamChunk) -> Unit { () }
  let first = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":null}}]},\"finish_reason\":null}]}"
  assert_false(process_oai_compat_sse(first, acc, noop))
  let cont = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":null,\"function\":{\"name\":null,\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}]},\"finish_reason\":null}]}"
  assert_false(process_oai_compat_sse(cont, acc, noop))
  // EOF here (no finish_reason, no [DONE]): the call is complete → tolerable.
  assert_true(oai_compat_eof_tolerable(acc))
}

///|
test "oai_compat_eof_tolerable rejects arguments cut mid-stream" {
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let noop = fn(_ : @posoco.StreamChunk) -> Unit { () }
  let first = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":null}}]},\"finish_reason\":null}]}"
  assert_false(process_oai_compat_sse(first, acc, noop))
  // Arguments JSON truncated: unparseable — the EOF must stay a loud failure.
  let cont = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":null,\"function\":{\"name\":null,\"arguments\":\"{\\\"cmd\\\":\\\"ls\"}}]},\"finish_reason\":null}]}"
  assert_false(process_oai_compat_sse(cont, acc, noop))
  assert_false(oai_compat_eof_tolerable(acc))
}

// ---------------------------------------------------------------------------
// models[] settings — per-model context_window / compact_threshold / efforts
// ---------------------------------------------------------------------------

///|
/// Build a source whose settings carry `models` = the parsed fixture text.
/// `Json::Array` is read-only, so fixture arrays come from `@json.parse`.
fn models_source(models_text : String) -> @llm.ProviderConfigSource {
  let models : Json = @json.parse(models_text) catch {
    _ => abort("models fixture JSON must parse")
  }
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-test")),
          ("base_url", Json::string("https://example.com/v1")),
          ("models", models),
        ]),
      ),
    ),
  )
}

///|
test "ProviderFactory::build with models produces per-model slots with metadata" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = models_source(
    "[{\"id\":\"qwen3-max\",\"context_window\":262144,\"compact_threshold\":0.85,\"reasoning_effort\":[\"low\",\"high\"]},{\"id\":\"qwen3-flash\",\"context_window\":131072}]",
  )
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      assert_eq(catalog.provider_id, "qwen")
      let slots = catalog.slots()
      assert_eq(slots.length(), 2)
      assert_eq(slots[0].id, "qwen/qwen3-max")
      assert_eq(slots[0].context_window, Some(262144))
      assert_eq(slots[0].port.provider_config().context_window, Some(262144))
      assert_eq(slots[0].port.provider_config().compact_threshold, Some(0.85))
      assert_eq(slots[0].thinking_efforts, ["off", "low", "high"])
      assert_eq(slots[1].id, "qwen/qwen3-flash")
      assert_eq(slots[1].context_window, Some(131072))
      // Undeclared threshold: the provider reports None and the core
      // default (0.88) applies downstream.
      assert_true(slots[1].port.provider_config().compact_threshold is None)
      assert_eq(slots[1].thinking_efforts, ["off", "on"])
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog from models array")
  }
}

///|
test "ProviderFactory::build rejects models combined with the flat model key" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let settings : Json = @json.parse(
    "{\"api_key\":\"sk-test\",\"base_url\":\"https://example.com/v1\",\"models\":[{\"id\":\"qwen3-max\"}],\"model\":\"qwen-plus\"}",
  ) catch {
    _ => abort("fixture JSON must parse")
  }
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(settings),
  )
  try factory.build(source) catch {
    error =>
      match error {
        @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
          assert_true(detail.contains("cannot combine"))
        _ => fail("expected ManifestSchemaError for models + flat model")
      }
  } noraise {
    _ => fail("expected composition failure for models + flat model")
  }
}

///|
test "ProviderFactory::build rejects out-of-range compact_threshold" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = models_source(
    "[{\"id\":\"qwen3-max\",\"context_window\":100000,\"compact_threshold\":1.5}]",
  )
  try factory.build(source) catch {
    error =>
      match error {
        @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
          assert_true(detail.contains("fraction in (0, 1]"))
        _ => fail("expected ManifestSchemaError for threshold 1.5")
      }
  } noraise {
    _ => fail("expected composition failure for threshold 1.5")
  }
}

///|
test "ProviderFactory::build rejects compact_threshold without context_window" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  let source = models_source(
    "[{\"id\":\"qwen3-max\",\"compact_threshold\":0.85}]",
  )
  try factory.build(source) catch {
    error =>
      match error {
        @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
          assert_true(detail.contains("requires context_window"))
        _ => fail("expected ManifestSchemaError for orphan threshold")
      }
  } noraise {
    _ => fail("expected composition failure for orphan threshold")
  }
}

///|
test "ProviderFactory::build rejects duplicate and empty models declarations" {
  let provider = OpenAICompatibleProvider("qwen")
  let factory : &@llm.ProviderFactory = provider
  try
    factory.build(
      models_source(
        "[{\"id\":\"qwen3-max\",\"context_window\":100000},{\"id\":\"qwen3-max\",\"context_window\":200000}]",
      ),
    )
  catch {
    error =>
      match error {
        @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
          assert_true(detail.contains("unique"))
        _ => fail("expected ManifestSchemaError for duplicate ids")
      }
  } noraise {
    _ => fail("expected composition failure for duplicate ids")
  }
  try factory.build(models_source("[]")) catch {
    error =>
      match error {
        @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
          assert_true(detail.contains("must not be empty"))
        _ => fail("expected ManifestSchemaError for empty models")
      }
  } noraise {
    _ => fail("expected composition failure for empty models")
  }
}

///|
test "compact summarize renderer covers roles, tool calls and outcomes" {
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("echo"),
    arguments: Json::object(Map::from_array([])),
  }
  let messages : Array[@posoco.Message] = [
    @posoco.Message::SystemMessage(content=[@posoco.Content::Text("sys")]),
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hello")]),
    @posoco.Message::AssistantMessage(
      content=[],
      tool_calls=[call],
      reasoning=None,
      finish_reason=@posoco.FinishReason::ToolCalls,
    ),
    @posoco.Message::ToolMessage(
      call_id=@posoco.CallId::unchecked("call_1"),
      tool_name=@posoco.ToolName::unchecked("echo"),
      outcome=@posoco.ToolOutcome::Success(content="echoed", structured=None),
    ),
  ]
  let rendered = oai_compat_compact_messages(messages)
  assert_eq(rendered.length(), 2)
  match rendered[0] {
    @posoco.Message::SystemMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(instruction) =>
          assert_true(instruction.contains("summarization engine"))
        _ => fail("expected instruction text")
      }
    _ => fail("expected system instruction")
  }
  match rendered[1] {
    @posoco.Message::UserMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(text) => {
          assert_true(text.contains("user: hello"))
          assert_true(text.contains("[tool call echo"))
          assert_true(text.contains("tool echo: echoed"))
        }
        _ => fail("expected transcript text")
      }
    _ => fail("expected transcript user message")
  }
}

///|
/// Image content three-state contract: no images → string content (some
/// compatible servers reject arrays); images + supports_images → typed parts;
/// images without support → string with an explicit placeholder, never a
/// silent drop.
test "build_chat_request encodes image content by model capability" {
  let opts = chat_options()
  let img_msg : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("look"),
    @posoco.Content::Image(media_type="image/png", data="aW1n"),
  ])
  // supports_images=true: typed parts array.
  let vision_body = build_chat_request(
    [img_msg],
    [],
    opts,
    "vision-model",
    false,
    false,
    None,
    true,
  )
  guard vision_body is Object(vf) else { fail("expected object") }
  guard vf.get("messages") is Some(Array([first, ..])) else {
    fail("expected one message")
  }
  guard first is Object(mf) else { fail("expected message object") }
  inspect(
    mf.get("content").unwrap_or(Json::null()).stringify(),
    content="[{\"type\":\"text\",\"text\":\"look\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,aW1n\"}}]",
  )
  // supports_images=false: string content with a visible placeholder.
  let text_body = build_chat_request(
    [img_msg],
    [],
    opts,
    "text-model",
    false,
    false,
    None,
    false,
  )
  guard text_body is Object(tf) else { fail("expected object") }
  guard tf.get("messages") is Some(Array([plain, ..])) else {
    fail("expected one message")
  }
  guard plain is Object(pf) else { fail("expected message object") }
  guard pf.get("content") is Some(String(content_str)) else {
    fail("expected string content")
  }
  assert_true(content_str.contains("look"))
  assert_true(content_str.contains("[Attached image/png"))
  assert_true(content_str.contains("omitted"))
  // Text-only message stays a plain string even with supports_images=true.
  let text_only = build_chat_request(
    [user_msg("hi")],
    [],
    opts,
    "vision-model",
    false,
    false,
    None,
    true,
  )
  guard text_only is Object(of) else { fail("expected object") }
  guard of.get("messages") is Some(Array([tmsg, ..])) else {
    fail("expected one message")
  }
  guard tmsg is Object(tmf) else { fail("expected message object") }
  inspect(
    tmf.get("content").unwrap_or(Json::null()).stringify(),
    content="\"hi\"",
  )
}
