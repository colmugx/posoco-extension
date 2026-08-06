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
  { temperature: None, max_output_tokens: None }
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
test "OpenAICompatibleConfig::new records required and optional fields" {
  let config = OpenAICompatibleConfig::new(
    "sk-test",
    base_url="https://example.com/v1",
    model="qwen-plus",
  )
  assert_eq(config.api_key, "sk-test")
  assert_eq(config.base_url, "https://example.com/v1")
  assert_eq(config.model, "qwen-plus")
  assert_eq(config.endpoint_prefix, "")
  assert_eq(config.reasoning_effort, "")
}

///|
test "OpenAICompatibleConfig::new carries optional fields" {
  let config = OpenAICompatibleConfig::new(
    "sk-test",
    base_url="https://example.com",
    model="qwen-plus",
    endpoint_prefix="/v1",
    reasoning_effort="medium",
  )
  assert_eq(config.endpoint_prefix, "/v1")
  assert_eq(config.reasoning_effort, "medium")
}

///|
test "OpenAICompatibleProvider::new scopes to the given provider id" {
  let provider = OpenAICompatibleProvider::new("qwen")
  let factory : &@llm.ProviderFactory = provider
  assert_eq(factory.provider_id(), "qwen")
  assert_eq(factory.credential_id(), "qwen")
}

///|
/// Build with no credential and no api_key setting → Unconfigured (the host
/// shows no slot rather than failing composition).
test "ProviderFactory::build returns Unconfigured without api_key" {
  let provider = OpenAICompatibleProvider::new("qwen")
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
  let provider = OpenAICompatibleProvider::new("qwen")
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
  let provider = OpenAICompatibleProvider::new("qwen")
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
  let provider = OpenAICompatibleProvider::new("qwen")
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
  let provider = OpenAICompatibleProvider::new("qwen")
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
  let provider = OpenAICompatibleProvider::new("qwen")
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
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) =>
      assert_true(detail.contains("OAuth credential is not supported"))
    _ => fail("expected ManifestSchemaError for OAuth credential")
  }
}

///|
async test "ApiKeyFactory::login validates and returns an opaque credential" {
  let provider = OpenAICompatibleProvider::new("qwen")
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = OaiCompatApiKeyPrompt::{ value: "sk-via-login" }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let credential = api.login(prompt)
  assert_eq(credential.secret, "sk-via-login")
}

///|
async test "ApiKeyFactory::login rejects an empty secret" {
  let provider = OpenAICompatibleProvider::new("qwen")
  let api : &@llm.ApiKeyFactory = provider
  let prompt_impl = OaiCompatApiKeyPrompt::{ value: "" }
  let prompt : &@oauth.AuthPromptInteraction = prompt_impl
  let result = Ok(api.login(prompt)) catch { error => Err(error) }
  match result {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("must not be empty"))
    _ => fail("expected empty API key to fail")
  }
}

///|
/// Build a request body and assert the optional reasoning_effort field is
/// emitted only when non-empty. This is the protocol-shape contract: plain
/// Chat Completions, no `thinking` wrapper, reasoning_effort as a top-level
/// field.
test "build_chat_request emits reasoning_effort only when non-empty" {
  let opts = chat_options()
  let with_effort = build_chat_request(
    [user_msg("hi")],
    [],
    opts,
    "qwen-plus",
    false,
    "medium",
  )
  guard with_effort is Object(with_fields) else {
    fail("expected request to be an object")
  }
  match with_fields.get("reasoning_effort") {
    Some(Json::String(value)) => assert_eq(value, "medium")
    _ => fail("expected reasoning_effort to be emitted when set")
  }
  match with_fields.get("thinking") {
    Some(_) =>
      fail("plain chat completions must not include a thinking wrapper")
    None => ()
  }

  let without_effort = build_chat_request(
    [user_msg("hi")],
    [],
    opts,
    "qwen-plus",
    false,
    "",
  )
  guard without_effort is Object(without_fields) else {
    fail("expected request to be an object")
  }
  match without_fields.get("reasoning_effort") {
    None => ()
    Some(_) => fail("reasoning_effort must be omitted when empty")
  }
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
    "",
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
  let body = build_chat_request([user_msg("hi")], [tool], opts, "m", true, "")
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
  let json = encode_message(msg)
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
    reasoning=Some(@posoco.Reasoning::{ content: "thinking about this..." }),
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let json = encode_message(msg)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    Some(String(r)) => assert_eq(r, "thinking about this...")
    _ => fail("reasoning_content MUST be present when tool_calls exist")
  }
}

///|
/// Without tool_calls, `reasoning_content` is optional and wasteful (pollutes
/// prefix cache) — omit it even when present.
test "encode_message_reasoning_omitted_without_tool_calls" {
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{ content: "thinking..." }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let json = encode_message(msg)
  guard json is Object(obj) else { fail("expected object") }
  match obj.get("reasoning_content") {
    None => ()
    _ => fail("reasoning_content should be omitted for non-tool-call turns")
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
  let provider = OpenAICompatibleProvider::new("qwen")
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
  let config = OpenAICompatibleConfig::new(
    "sk-test",
    base_url="https://example.com/v1",
    model="qwen-plus",
    reasoning_effort="high",
    thinking_efforts=["low", "high"],
  )
  let port = OpenAICompatibleModelPort::new("qwen", config)
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
test "OpenAICompatibleConfig::with_reasoning_effort maps off to omitted field and validates membership" {
  let config = OpenAICompatibleConfig::new(
    "sk-test",
    base_url="https://example.com/v1",
    model="qwen-plus",
    reasoning_effort="high",
    thinking_efforts=["low", "high"],
  )
  assert_eq(config.with_reasoning_effort("off").reasoning_effort, "")
  assert_eq(config.with_reasoning_effort("low").reasoning_effort, "low")
  let invalid = Ok(config.with_reasoning_effort("max")) catch {
    err => Err(err)
  }
  match invalid {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("unsupported reasoning effort"))
    _ => fail("an undeclared effort must fail at the config boundary")
  }
}

///|
test "ProviderFactory::build rejects a singular effort outside the declared list" {
  let provider = OpenAICompatibleProvider::new("qwen")
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
  let provider = OpenAICompatibleProvider::new("qwen")
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
