///|
fn qwen_settings(pairs : Array[(String, Json)]) -> @llm.ProviderConfigSource {
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object(Map::from_array(pairs))),
  )
}

///|
test "factory is unconfigured without an API key" {
  let result = @llm.ProviderFactory::build(QwenProvider(), qwen_settings([]))
  assert_true(result is @llm.ProviderBuildResult::Unconfigured)
}

///|
test "known Qwen3.8 defaults expose thinking and tool streaming" {
  let config = QwenConfig(
    "k",
    base_url="https://example.com/v1",
    model="qwen3.8-max",
  )
  assert_eq(config.reasoning_effort, Some("xhigh"))
  assert_true(config.preserve_thinking)
  assert_true(config.tool_stream)
  assert_true(config.supports_images)
  debug_inspect(
    qwen_slot_efforts(config),
    content="["off", "low", "medium", "xhigh"]",
  )
}

///|
test "off maps to Qwen reasoning_effort none" {
  let config = QwenConfig(
    "k",
    base_url="https://example.com/v1",
    model="qwen3.8-max",
  )
  let off = config.with_reasoning_effort("off")
  assert_eq(off.reasoning_effort, Some("none"))
  assert_true(off.enable_thinking is None)
}

///|
test "request replays reasoning_content when preserve_thinking is enabled" {
  let config = QwenConfig(
    "k",
    base_url="https://example.com/v1",
    model="qwen3.8-max",
  )
  let messages : Array[@posoco.Message] = [
    @posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("answer")],
      tool_calls=[],
      reasoning=Some(@posoco.Reasoning::{ content: "think", raw: None, }),
      finish_reason=@posoco.FinishReason::Stop,
    ),
  ]
  let body = build_chat_request(
    config,
    messages,
    [],
    @posoco.ChatOptions::{ temperature: None, max_output_tokens: None, },
    false,
  )
  guard body is Json::Object(root) else { fail("expected object") }
  guard root.get("messages") is Some(Json::Array(encoded)) else {
    fail("expected messages")
  }
  guard encoded[0] is Json::Object(message) else { fail("expected message") }
  assert_eq(message.get("reasoning_content"), Some(Json::string("think")))
  assert_eq(root.get("preserve_thinking"), Some(Json::boolean(true)))
  assert_eq(root.get("reasoning_effort"), Some(Json::string("xhigh")))
}

///|
test "stream request enables tool_stream and usage" {
  let config = QwenConfig(
    "k",
    base_url="https://example.com/v1",
    model="qwen3.8-flash",
  )
  let body = build_chat_request(
    config,
    [],
    [],
    @posoco.ChatOptions::{ temperature: None, max_output_tokens: None, },
    true,
  )
  guard body is Json::Object(root) else { fail("expected object") }
  assert_eq(root.get("tool_stream"), Some(Json::boolean(true)))
  assert_eq(root.get("stream"), Some(Json::boolean(true)))
  assert_true(root.get("stream_options") is Some(_))
}

///|
test "factory accepts Token Plan base URL unchanged" {
  let result = @llm.ProviderFactory::build(
    QwenProvider(),
    qwen_settings([
      ("api_key", Json::string("sk-sp-test")),
      (
        "base_url",
        Json::string(
          "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
        ),
      ),
      ("model", Json::string("qwen3.8-max")),
    ]),
  )
  guard result is @llm.ProviderBuildResult::Ready(catalog) else {
    fail("expected Ready")
  }
  assert_eq(catalog.provider_id, "qwen")
  assert_eq(catalog.slots.length(), 1)
  assert_eq(catalog.slots[0].model_id, "qwen3.8-max")
}
