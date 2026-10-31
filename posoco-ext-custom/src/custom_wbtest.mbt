///|
/// Whitebox tests for posoco-ext-custom: the protocol vocabulary, the
/// settings → catalog path, credential placement, and the three request
/// shapes. Everything here is pure — streaming and live HTTP behavior are
/// validated through the host integration surface.

///|
fn user_msg(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
fn chat_options() -> @posoco.ChatOptions {
  { temperature: None, max_output_tokens: None, }
}

///|
fn settings_source(fields : Array[(String, Json)]) -> @llm.ProviderConfigSource {
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object(Map::from_array(fields))),
  )
}

///|
/// Provider-neutral prompt fake used to exercise the API-key seam.
struct CustomApiKeyPrompt {
  value : String
}

///|
pub impl @oauth.AuthPromptInteraction for CustomApiKeyPrompt with fn prompt(
  self : CustomApiKeyPrompt,
  _request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  self.value
}

///|
pub extend CustomApiKeyPrompt with @oauth.AuthPromptInteraction::{prompt}

///|
test "protocol ids round-trip and unknown ids stay unknown" {
  for
    protocol in [
      CustomProtocol::ChatCompletions,
      CustomProtocol::Responses,
      CustomProtocol::Messages,
    ] {
    assert_eq(custom_protocol_of_id(protocol.to_id()), Some(protocol))
  }
  assert_eq(custom_protocol_of_id("chat"), None)
  assert_eq(custom_protocol_of_id("Chat_Completions"), None)
  assert_eq(custom_protocol_of_id(""), None)
  assert_eq(custom_protocol_choices(), "chat_completions, responses, messages")
}

///|
test "auth ids round-trip and unknown ids stay unknown" {
  for auth in [CustomAuth::Auto, CustomAuth::Bearer, CustomAuth::ApiKeyHeader] {
    assert_eq(custom_auth_of_id(auth.to_id()), Some(auth))
  }
  assert_eq(custom_auth_of_id("x-api-key"), None)
  assert_eq(custom_auth_choices(), "auto, bearer, x_api_key")
}

///|
test "config defaults to the chat-completions wire" {
  let config = CustomConfig(
    "sk-test",
    base_url="https://example.com/v1",
    model="qwen-plus",
  )
  assert_eq(config.protocol, CustomProtocol::ChatCompletions)
  assert_eq(config.auth, CustomAuth::Auto)
  assert_eq(config.max_output_tokens, CUSTOM_DEFAULT_MAX_OUTPUT_TOKENS)
  assert_eq(config.endpoint_prefix, "")
  assert_eq(config.reasoning_effort, None)
  assert_true(config.thinking_efforts.is_empty())
}

///|
/// Rebuild helpers are record updates: a field added to the config later must
/// reach every rebuild site without anyone remembering to copy it.
test "with_api_key preserves every other field" {
  let config = CustomConfig(
    "sk-test",
    base_url="https://example.com",
    model="m",
    endpoint_prefix="/v1",
    protocol=CustomProtocol::Messages,
    auth=CustomAuth::Bearer,
    max_output_tokens=4096,
    reasoning_effort=Some("high"),
    thinking_efforts=["low", "high"],
    context_window=Some(200000),
    compact_threshold=Some(0.9),
    supports_images=true,
    send_prompt_cache_key=true,
  )
  let rebuilt = config.with_api_key("sk-new")
  assert_eq(rebuilt.api_key, "sk-new")
  assert_eq(rebuilt.base_url, "https://example.com")
  assert_eq(rebuilt.endpoint_prefix, "/v1")
  assert_eq(rebuilt.protocol, CustomProtocol::Messages)
  assert_eq(rebuilt.auth, CustomAuth::Bearer)
  assert_eq(rebuilt.max_output_tokens, 4096)
  assert_eq(rebuilt.reasoning_effort, Some("high"))
  assert_eq(rebuilt.thinking_efforts, ["low", "high"])
  assert_eq(rebuilt.context_window, Some(200000))
  assert_eq(rebuilt.compact_threshold, Some(0.9))
  assert_true(rebuilt.supports_images)
  assert_true(rebuilt.send_prompt_cache_key)
}

///|
test "with_reasoning_effort accepts declared levels and off" {
  let config = CustomConfig(
    "sk",
    base_url="https://example.com",
    model="m",
    thinking_efforts=["low", "high"],
    reasoning_effort=Some("low"),
  )
  assert_eq(config.with_reasoning_effort("high").reasoning_effort, Some("high"))
  assert_eq(config.with_reasoning_effort("off").reasoning_effort, None)
  let rejected = Ok(config.with_reasoning_effort("max")) catch {
    error => Err(error)
  }
  match rejected {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("unsupported reasoning effort"))
    _ => fail("expected an undeclared effort to fail")
  }
}

///|
test "provider scopes to the given id on both seams" {
  let provider = CustomProvider("my-gateway")
  let factory : &@llm.ProviderFactory = provider
  assert_eq(factory.provider_id(), "my-gateway")
  assert_eq(factory.credential_id(), "my-gateway")
  let api : &@llm.ApiKeyFactory = provider
  assert_eq(api.credential_id(), "my-gateway")
}

///|
test "build returns Unconfigured without api_key, base_url, or model" {
  let factory : &@llm.ProviderFactory = CustomProvider("gw")
  let no_key = settings_source([
    ("base_url", Json::string("https://example.com/v1")),
    ("model", Json::string("m")),
  ])
  let no_base = settings_source([
    ("api_key", Json::string("sk")),
    ("model", Json::string("m")),
  ])
  let no_model = settings_source([
    ("api_key", Json::string("sk")),
    ("base_url", Json::string("https://example.com/v1")),
  ])
  for source in [no_key, no_base, no_model] {
    match factory.build(source) {
      @llm.ProviderBuildResult::Unconfigured => ()
      @llm.ProviderBuildResult::Ready(_) =>
        fail("expected Unconfigured when a required setting is missing")
    }
  }
}

///|
test "flat settings build one slot and keep the custom display group" {
  let factory : &@llm.ProviderFactory = CustomProvider("my-gateway")
  let source = settings_source([
    ("api_key", Json::string("sk")),
    ("base_url", Json::string("https://example.com/v1")),
    ("model", Json::string("qwen-plus")),
  ])
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      assert_eq(catalog.provider_id, "my-gateway")
      let slots = catalog.slots()
      assert_eq(slots.length(), 1)
      let slot = slots[0]
      assert_eq(slot.id, "my-gateway/qwen-plus")
      assert_eq(slot.display_group, Some("custom"))
      // The flat style declares no window: an undeclared window keeps
      // auto-compact off instead of guessing one.
      assert_eq(slot.context_window, None)
      assert_true(slot.capabilities.contains("chat"))
      assert_true(slot.capabilities.contains("streaming"))
      assert_true(slot.capabilities.contains("api_key"))
      assert_eq(slot.port.provider_config().context_window, None)
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
/// The declared protocol rides on the port that ends up in the slot. The port
/// is a trait object, so the observable proof is the wire it builds: a
/// `messages` provider must produce the Anthropic credential header.
test "protocol reaches the port: messages provider sends x-api-key" {
  let factory : &@llm.ProviderFactory = CustomProvider("claude-proxy")
  let source = settings_source([
    ("api_key", Json::string("sk-ant")),
    ("base_url", Json::string("https://example.com")),
    ("endpoint_prefix", Json::string("/v1")),
    ("model", Json::string("claude-sonnet-5")),
    ("protocol", Json::string("messages")),
  ])
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      let headers = build_wire_headers(
        CustomConfig(
          "sk-ant",
          base_url="https://example.com",
          model="claude-sonnet-5",
          protocol=CustomProtocol::Messages,
        ),
        None,
      )
      assert_eq(
        headers.get(@http.CaseInsensitiveString("x-api-key")),
        Some("sk-ant"),
      )
      assert_eq(
        headers.get(@http.CaseInsensitiveString("anthropic-version")),
        Some("2023-06-01"),
      )
      assert_true(slot.port.provider_config().context_window is None)
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
test "an unknown protocol is a typed composition failure" {
  let factory : &@llm.ProviderFactory = CustomProvider("gw")
  let source = settings_source([
    ("api_key", Json::string("sk")),
    ("base_url", Json::string("https://example.com/v1")),
    ("model", Json::string("m")),
    ("protocol", Json::string("grpc")),
  ])
  let result = Ok(factory.build(source)) catch { error => Err(error) }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) => {
      assert_true(detail.contains("unknown protocol: grpc"))
      assert_true(detail.contains("chat_completions, responses, messages"))
    }
    _ => fail("expected ManifestSchemaError for an unknown protocol")
  }
}

///|
test "an unknown auth style is a typed composition failure" {
  let factory : &@llm.ProviderFactory = CustomProvider("gw")
  let source = settings_source([
    ("api_key", Json::string("sk")),
    ("base_url", Json::string("https://example.com/v1")),
    ("model", Json::string("m")),
    ("auth", Json::string("basic")),
  ])
  let result = Ok(factory.build(source)) catch { error => Err(error) }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("unknown style: basic"))
    _ => fail("expected ManifestSchemaError for an unknown auth style")
  }
}

///|
/// One endpoint may serve several models on different wires; the per-model
/// override wins over the provider-level default.
test "models entries override the provider protocol per model" {
  let factory : &@llm.ProviderFactory = CustomProvider("gw")
  let source = settings_source([
    ("api_key", Json::string("sk")),
    ("base_url", Json::string("https://example.com/v1")),
    ("protocol", Json::string("messages")),
    (
      "models",
      Json::array([
        Json::object(Map::from_array([("id", Json::string("claude-a"))])),
        Json::object(
          Map::from_array([
            ("id", Json::string("gpt-b")),
            ("protocol", Json::string("responses")),
          ]),
        ),
      ]),
    ),
  ])
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      assert_eq(catalog.slots().length(), 2)
      let ids = catalog.slots().map(fn(slot) { slot.model_id })
      assert_eq(ids, ["claude-a", "gpt-b"])
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with models[]")
  }
}

///|
test "models entries reject an unknown protocol" {
  let factory : &@llm.ProviderFactory = CustomProvider("gw")
  let source = settings_source([
    ("api_key", Json::string("sk")),
    ("base_url", Json::string("https://example.com/v1")),
    (
      "models",
      Json::array([
        Json::object(
          Map::from_array([
            ("id", Json::string("m")),
            ("protocol", Json::string("soap")),
          ]),
        ),
      ]),
    ),
  ])
  let result = Ok(factory.build(source)) catch { error => Err(error) }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("models entry 'm' protocol"))
    _ => fail("expected ManifestSchemaError for a bad per-model protocol")
  }
}

///|
test "rebuild closures keep the catalog's other facts" {
  let factory : &@llm.ProviderFactory = CustomProvider("gw")
  let source = settings_source([
    ("api_key", Json::string("sk")),
    ("base_url", Json::string("https://example.com/v1")),
    ("protocol", Json::string("responses")),
    (
      "models",
      Json::array([
        Json::object(
          Map::from_array([
            ("id", Json::string("m")),
            ("context_window", Json::number(200000.0)),
            ("compact_threshold", Json::number(0.8)),
            (
              "reasoning_efforts",
              Json::array([Json::string("low"), Json::string("high")]),
            ),
          ]),
        ),
      ]),
    ),
  ])
  match factory.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) => {
      let slot = catalog.slots()[0]
      assert_eq(slot.thinking_efforts, ["off", "low", "high"])
      assert_eq(slot.default_effort, Some("low"))
      let rebuilt_effort = match slot.rebuild_on_effort {
        Some(rebuild) => Some(rebuild("high"))
        None => None
      }
      let rebuilt = match rebuilt_effort {
        Some(value) => value
        None => fail("expected an effort rebuild hook")
      }
      assert_eq(rebuilt.default_effort, Some("high"))
      assert_eq(rebuilt.context_window, Some(200000))
      assert_eq(rebuilt.port.provider_config().compact_threshold, Some(0.8))
      let rebuilt_key = match slot.rebuild_on_api_key {
        Some(rebuild) =>
          rebuild(@oauth.ApiKeyCredential::ApiKeyCredential(secret="sk-new"))
        None => fail("expected an api-key rebuild hook")
      }
      assert_eq(rebuilt_key.context_window, Some(200000))
      assert_eq(rebuilt_key.display_group, Some("custom"))
    }
    @llm.ProviderBuildResult::Unconfigured =>
      fail("expected Ready catalog with full settings")
  }
}

///|
test "api_key credential wins over the api_key setting" {
  let factory : &@llm.ProviderFactory = CustomProvider("gw")
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("sk-from-settings")),
          ("base_url", Json::string("https://example.com/v1")),
          ("model", Json::string("m")),
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
      fail("expected Ready when an api_key credential is present")
  }
}

///|
test "OAuth credentials are rejected for a custom id" {
  let factory : &@llm.ProviderFactory = CustomProvider("gw")
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("base_url", Json::string("https://example.com/v1")),
          ("model", Json::string("m")),
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
    _ => fail("expected ManifestSchemaError for an OAuth credential")
  }
}

///|
async test "login returns the entered secret and rejects an empty one" {
  let provider = CustomProvider("gw")
  let api : &@llm.ApiKeyFactory = provider
  let entered = CustomApiKeyPrompt::{ value: "sk-via-login", }
  let prompt : &@oauth.AuthPromptInteraction = entered
  assert_eq(api.login(prompt).secret, "sk-via-login")
  let blank = CustomApiKeyPrompt::{ value: "", }
  let blank_prompt : &@oauth.AuthPromptInteraction = blank
  let result = Ok(api.login(blank_prompt)) catch { error => Err(error) }
  match result {
    Err(@oauth.OAuthError::ParseError(message)) =>
      assert_true(message.contains("must not be empty"))
    _ => fail("expected an empty API key to fail")
  }
}

///|
test "credential headers follow the protocol and the auth override" {
  let chat = CustomConfig("sk", base_url="https://e/v1", model="m")
  let chat_headers = build_wire_headers(chat, None)
  assert_eq(
    chat_headers.get(@http.CaseInsensitiveString("Authorization")),
    Some("Bearer sk"),
  )
  assert_eq(chat_headers.get(@http.CaseInsensitiveString("x-api-key")), None)

  let keyed = CustomConfig(
    "sk",
    base_url="https://e/v1",
    model="m",
    auth=CustomAuth::ApiKeyHeader,
  )
  let keyed_headers = build_wire_headers(keyed, None)
  assert_eq(
    keyed_headers.get(@http.CaseInsensitiveString("x-api-key")),
    Some("sk"),
  )
  assert_eq(
    keyed_headers.get(@http.CaseInsensitiveString("Authorization")),
    None,
  )

  let messages = CustomConfig(
    "sk",
    base_url="https://e/v1",
    model="m",
    protocol=CustomProtocol::Messages,
  )
  let messages_headers = build_wire_headers(messages, None)
  assert_eq(
    messages_headers.get(@http.CaseInsensitiveString("x-api-key")),
    Some("sk"),
  )
  assert_eq(
    messages_headers.get(@http.CaseInsensitiveString("anthropic-version")),
    Some("2023-06-01"),
  )

  let messages_bearer = CustomConfig(
    "sk",
    base_url="https://e/v1",
    model="m",
    protocol=CustomProtocol::Messages,
    auth=CustomAuth::Bearer,
  )
  let bearer_headers = build_wire_headers(messages_bearer, None)
  assert_eq(
    bearer_headers.get(@http.CaseInsensitiveString("Authorization")),
    Some("Bearer sk"),
  )
  assert_eq(bearer_headers.get(@http.CaseInsensitiveString("x-api-key")), None)
}

///|
test "a request_headers hook overrides the wire defaults" {
  let config = CustomConfig("sk", base_url="https://e/v1", model="m")
  let headers = build_wire_headers(
    config,
    Some(fn() {
      Map::from_array([
        ("Authorization", "Bearer rotated"),
        ("X-Route", "team-a"),
      ])
    }),
  )
  assert_eq(
    headers.get(@http.CaseInsensitiveString("Authorization")),
    Some("Bearer rotated"),
  )
  assert_eq(headers.get(@http.CaseInsensitiveString("X-Route")), Some("team-a"))
}

///|
test "chat wire body carries the turn and the stream flags" {
  let body = build_chat_request(
    [user_msg("hi")],
    [],
    chat_options(),
    "m",
    true,
    Some("high"),
    Some("cache-1"),
    false,
  )
  let text = body.stringify()
  assert_true(text.contains("\"model\":\"m\""))
  assert_true(
    text.contains("\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]"),
  )
  assert_true(text.contains("\"reasoning_effort\":\"high\""))
  assert_true(text.contains("\"prompt_cache_key\":\"cache-1\""))
  assert_true(text.contains("\"stream\":true"))
  assert_true(text.contains("\"stream_options\":{\"include_usage\":true}"))
}

///|
test "responses wire body lifts system into instructions" {
  let config = CustomConfig(
    "sk",
    base_url="https://example.com/v1",
    model="gpt-x",
    protocol=CustomProtocol::Responses,
  )
  let body = build_responses_request(
    config,
    [
      @posoco.Message::SystemMessage(content=[@posoco.Content::Text("be terse")]),
      user_msg("hi"),
    ],
    [],
    chat_options(),
  )
  let text = body.stringify()
  assert_true(text.contains("\"instructions\":\"be terse\""))
  assert_true(text.contains("\"store\":false"))
  assert_true(text.contains("\"model\":\"gpt-x\""))
  assert_true(!text.contains("reasoning"))
}

///|
test "responses wire sends reasoning effort and drops temperature" {
  let config = CustomConfig(
    "sk",
    base_url="https://example.com/v1",
    model="gpt-x",
    protocol=CustomProtocol::Responses,
    reasoning_effort=Some("high"),
    thinking_efforts=["high"],
  )
  let body = build_responses_request(config, [user_msg("hi")], [], {
    temperature: Some(0.2),
    max_output_tokens: None,
  })
  let text = body.stringify()
  assert_true(text.contains("\"reasoning\":{\"effort\":\"high\"}"))
  assert_true(!text.contains("temperature"))
}

///|
test "messages wire body sends system, max_tokens, thinking, and stream" {
  let config = CustomConfig(
    "sk",
    base_url="https://example.com",
    model="claude-x",
    endpoint_prefix="/v1",
    protocol=CustomProtocol::Messages,
    reasoning_effort=Some("high"),
    thinking_efforts=["high"],
  )
  let body = build_messages_request(
    config,
    [
      @posoco.Message::SystemMessage(content=[@posoco.Content::Text("be terse")]),
      user_msg("hi"),
    ],
    [],
    chat_options(),
    stream=true,
  )
  let text = body.stringify()
  assert_true(text.contains("\"max_tokens\":8192"))
  assert_true(text.contains("\"stream\":true"))
  assert_true(text.contains("\"thinking\":{\"type\":\"enabled\"}"))
  assert_true(text.contains("\"system\""))
  assert_true(!text.contains("\"role\":\"system\""))
}

///|
test "messages wire takes the turn's output ceiling when the host set one" {
  let config = CustomConfig(
    "sk",
    base_url="https://example.com",
    model="claude-x",
    protocol=CustomProtocol::Messages,
  )
  let body = build_messages_request(config, [user_msg("hi")], [], {
    temperature: None,
    max_output_tokens: Some(512),
  })
  assert_true(body.stringify().contains("\"max_tokens\":512"))
}

///|
test "messages wire omits thinking when no level is selected" {
  let config = CustomConfig(
    "sk",
    base_url="https://example.com",
    model="claude-x",
  )
  let body = build_messages_request(
    config,
    [user_msg("hi")],
    [],
    chat_options(),
  )
  assert_true(!body.stringify().contains("thinking"))
}

///|
test "images downgrade to an explicit placeholder without image support" {
  let shaped = shape_custom_images(
    [
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Image(media_type="image/png", data="AAAA"),
      ]),
    ],
    false,
  )
  match shaped[0] {
    @posoco.Message::UserMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(text) =>
          assert_true(
            text.contains("omitted: this model does not accept image"),
          )
        _ => fail("expected the image to downgrade to text")
      }
    _ => fail("expected a user message")
  }
  // With image support declared the block is preserved for the kit to encode.
  let kept = shape_custom_images(
    [
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Image(media_type="image/png", data="AAAA"),
      ]),
    ],
    true,
  )
  match kept[0] {
    @posoco.Message::UserMessage(content~) =>
      match content[0] {
        @posoco.Content::Image(..) => ()
        _ => fail("expected the image block to survive")
      }
    _ => fail("expected a user message")
  }
}

///|
test "compact request is plain prose with images named, not sent" {
  let messages = custom_compact_messages([
    user_msg("hi"),
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Image(media_type="image/png", data="AAAA"),
    ]),
  ])
  assert_eq(messages.length(), 2)
  match messages[0] {
    @posoco.Message::SystemMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(text) =>
          assert_true(text.contains("summarization engine"))
        _ => fail("expected a text system prompt")
      }
    _ => fail("expected a system message first")
  }
  match messages[1] {
    @posoco.Message::UserMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(text) =>
          assert_true(text.contains("[image: image/png]"))
        _ => fail("expected rendered transcript text")
      }
    _ => fail("expected a user message second")
  }
}
