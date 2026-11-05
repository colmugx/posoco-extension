///|
/// Hosted OpenAI Web Search tests. The approved seams are the public provider
/// settings/catalog rebuild and the public `OpenAIModelPort.chat` request
/// against the loopback HTTP fixture: every assertion here reads the bytes the
/// production chat path actually put on the wire, or the mode the provider
/// configuration carried into a rebuilt slot.

///|
#cfg(target="native")
fn ws_chat_reply() -> String {
  "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}]}"
}

///|
/// One non-streaming chat round trip over the loopback fixture. The caller
/// builds the config from the served base URL so the production port owns the
/// request, headers and URL splitting.
#cfg(target="native")
async fn ws_chat_wire(
  config_of : (String) -> OpenAIConfig,
  tools~ : Array[@posoco.ToolDef] = latest_fixture_tools(),
) -> CompactLoopback {
  let server = CompactLoopback::bind([
    Respond(status=200, body=ws_chat_reply(), headers=[], delay_ms=0),
  ])
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      defer server.stop()
      let _ = group.spawn(() => server.serve(), allow_failure=true)
      let config = config_of("http://127.0.0.1:\{server.server.addr.port()}/v1")
      let port = OpenAIModelPort::OpenAIModelPort(config)
      let _ = port.chat(
        compact_loopback_scope(),
        compact_loopback_messages(),
        tools,
        { temperature: None, max_output_tokens: None, },
        @posoco.StreamMode::NoStream,
      ) catch {
        err => fail("chat failed: \{err}")
      }
    }
  })
  server
}

///|
#cfg(target="native")
fn ws_body_fields(body : String) -> Map[String, Json] raise {
  guard @json.parse(body) is Json::Object(fields) else {
    fail("request body must be a JSON object")
  }
  fields
}

///|
#cfg(target="native")
fn ws_hosted_tool(external_web_access : Bool) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("web_search")),
      ("external_web_access", Json::boolean(external_web_access)),
    ]),
  )
}

///|
#cfg(target="native")
async test "openai_chat_wire_declares_cached_web_search_by_default" {
  let server = ws_chat_wire(fn(base_url) {
    OpenAIConfig::with_base_url("ws-test-key", "gpt-5", base_url).with_reasoning_effort(
      "medium",
    )
  })
  let fields = ws_body_fields(server.bodies[0])
  guard fields.get("tools") is Some(Json::Array(tools)) else { fail("tools") }
  assert_eq(tools.length(), 2)
  assert_eq(
    tools[0],
    @responses.tool_to_responses_wire(latest_fixture_tools()[0]),
  )
  assert_eq(tools[1], ws_hosted_tool(false))
  assert_eq(
    fields.get("include"),
    Some(Json::array([Json::string("reasoning.encrypted_content")])),
  )
}

///|
#cfg(target="native")
async test "openai_chat_wire_maps_live_and_declares_without_function_tools" {
  let server = ws_chat_wire(
    fn(base_url) {
      OpenAIConfig::with_base_url("ws-test-key", "gpt-5", base_url).with_web_search(
        OpenAIWebSearchMode::Live,
      )
    },
    tools=[],
  )
  let fields = ws_body_fields(server.bodies[0])
  // Hosted search alone still declares the tools array: a search-only turn
  // must not lose the capability just because no function tool is mounted.
  assert_eq(fields.get("tools"), Some(Json::array([ws_hosted_tool(true)])))
  assert_eq(fields.get("include"), None)
}

///|
#cfg(target="native")
async test "openai_chat_wire_disabled_web_search_sends_no_hosted_tool" {
  let with_tools = ws_chat_wire(fn(base_url) {
    OpenAIConfig::with_base_url("ws-test-key", "gpt-5", base_url).with_web_search(
      OpenAIWebSearchMode::Disabled,
    )
  })
  let fields = ws_body_fields(with_tools.bodies[0])
  assert_eq(
    fields.get("tools"),
    Some(
      Json::array(latest_fixture_tools().map(@responses.tool_to_responses_wire)),
    ),
  )
  let without_tools = ws_chat_wire(
    fn(base_url) {
      OpenAIConfig::with_base_url("ws-test-key", "gpt-5", base_url).with_web_search(
        OpenAIWebSearchMode::Disabled,
      )
    },
    tools=[],
  )
  assert_false(ws_body_fields(without_tools.bodies[0]).contains("tools"))
}

///|
#cfg(target="native")
async test "openai_web_search_setting_rejects_unknown_mode_and_wrong_type" {
  let provider = OpenAIProvider()
  try
    provider.build(
      @llm.ProviderConfigSource::ProviderConfigSource(
        settings=Some(
          @json.parse("{\"api_key\":\"ws-test-key\",\"web_search\":\"bogus\"}"),
        ),
      ),
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
      assert_eq(manifest_id, "posoco_ext_openai")
      assert_true(detail.contains("web_search"))
      assert_true(detail.contains("bogus"))
    }
    _ => fail("an unknown web_search mode must be a typed composition error")
  } noraise {
    _ => fail("an unknown web_search mode must fail composition")
  }
  try
    provider.build(
      @llm.ProviderConfigSource::ProviderConfigSource(
        settings=Some(
          @json.parse("{\"api_key\":\"ws-test-key\",\"web_search\":true}"),
        ),
      ),
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
      assert_eq(manifest_id, "posoco_ext_openai")
      assert_true(detail.contains("web_search"))
    }
    _ =>
      fail("a non-string web_search setting must be a typed composition error")
  } noraise {
    _ => fail("a non-string web_search setting must fail composition")
  }
}

///|
#cfg(target="native")
fn ws_chat_options() -> @posoco.ChatOptions {
  { temperature: None, max_output_tokens: None, }
}

///|
#cfg(target="native")
async test "openai_web_search_mode_survives_catalog_effort_and_key_rebuild" {
  let server = CompactLoopback::bind([
    Respond(status=200, body=ws_chat_reply(), headers=[], delay_ms=0),
  ])
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      defer server.stop()
      let _ = group.spawn(() => server.serve(), allow_failure=true)
      let source = @llm.ProviderConfigSource::ProviderConfigSource(
        settings=Some(
          @json.parse(
            "{\"model\":\"gpt-5\",\"web_search\":\"live\",\"base_url\":\"http://127.0.0.1:\{server.server.addr.port()}/v1\"}",
          ),
        ),
        provider_credential=Some(
          @oauth.ProviderCredential::ApiKey(
            @oauth.ApiKeyCredential::ApiKeyCredential(secret="ws-test-key"),
          ),
        ),
        cached_models=Some(
          @json.parse(
            "[{\"model_id\":\"gpt-5\",\"thinking_efforts\":[\"low\",\"high\"],\"default_effort\":\"low\"}]",
          ),
        ),
      )
      let catalog = match OpenAIProvider().build(source) {
        @llm.ProviderBuildResult::Ready(catalog) => catalog
        @llm.ProviderBuildResult::Unconfigured =>
          fail("an api-key source with a cache must build")
      }
      let slot = catalog.slots()[0]
      let slot = slot.rebuild_on_effort.unwrap()("high")
      let slot = slot.rebuild_on_api_key.unwrap()(
        @oauth.ApiKeyCredential::ApiKeyCredential(secret="ws-rotated-key"),
      )
      let _ = slot.port.chat(
        compact_loopback_scope(),
        compact_loopback_messages(),
        latest_fixture_tools(),
        ws_chat_options(),
        @posoco.StreamMode::NoStream,
      ) catch {
        err => fail("chat failed: \{err}")
      }
    }
  })
  let fields = ws_body_fields(server.bodies[0])
  guard fields.get("tools") is Some(Json::Array(tools)) else { fail("tools") }
  assert_eq(tools[tools.length() - 1], ws_hosted_tool(true))
  guard fields.get("reasoning") is Some(Json::Object(reasoning)) else {
    fail("reasoning")
  }
  assert_eq(reasoning.get("effort"), Some(Json::string("high")))
  assert_eq(
    server.requests[0].headers.get("Authorization"),
    Some("Bearer ws-rotated-key"),
  )
}

///|
#cfg(target="native")
async test "openai_lite_chat_wire_sends_no_hosted_web_search" {
  let server = ws_chat_wire(fn(base_url) {
    {
      ..OpenAIConfig::with_base_url("ws-test-key", "gpt-5", base_url),
      use_responses_lite: true,
      reasoning_effort: Some("medium"),
      web_search: OpenAIWebSearchMode::Live,
    }
  })
  let fields = ws_body_fields(server.bodies[0])
  // Lite carries tools as an inline developer item; hosted search has no slot
  // there, so it must be absent from both the top-level field and the item.
  assert_false(fields.contains("tools"))
  assert_false(server.bodies[0].contains("web_search"))
  guard fields.get("input") is Some(Json::Array(input)) &&
    input[0] is Json::Object(additional) else {
    fail("lite additional_tools")
  }
  assert_eq(additional.get("type"), Some(Json::string("additional_tools")))
  assert_eq(
    additional.get("tools"),
    Some(
      Json::array(latest_fixture_tools().map(@responses.tool_to_responses_wire)),
    ),
  )
}

///|
/// Provider-build-to-wire path without any rebuild hop: settings and the
/// host-cached discovery records decide the slot, then the public port sends
/// the request to the loopback endpoint.
#cfg(target="native")
async fn ws_provider_chat_wire(
  settings_of : (String) -> String,
  cached_models~ : String,
) -> CompactLoopback {
  let server = CompactLoopback::bind([
    Respond(status=200, body=ws_chat_reply(), headers=[], delay_ms=0),
  ])
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      defer server.stop()
      let _ = group.spawn(() => server.serve(), allow_failure=true)
      let source = @llm.ProviderConfigSource::ProviderConfigSource(
        settings=Some(
          @json.parse(
            settings_of("http://127.0.0.1:\{server.server.addr.port()}/v1"),
          ),
        ),
        provider_credential=Some(
          @oauth.ProviderCredential::ApiKey(
            @oauth.ApiKeyCredential::ApiKeyCredential(secret="ws-test-key"),
          ),
        ),
        cached_models=Some(@json.parse(cached_models)),
      )
      let catalog = match OpenAIProvider().build(source) {
        @llm.ProviderBuildResult::Ready(catalog) => catalog
        @llm.ProviderBuildResult::Unconfigured =>
          fail("an api-key source with a cache must build")
      }
      let _ = catalog.slots()[0].port.chat(
        compact_loopback_scope(),
        compact_loopback_messages(),
        latest_fixture_tools(),
        ws_chat_options(),
        @posoco.StreamMode::NoStream,
      ) catch {
        err => fail("chat failed: \{err}")
      }
    }
  })
  server
}

///|
#cfg(target="native")
async test "openai_web_search_disabled_setting_survives_cached_catalog" {
  let server = ws_provider_chat_wire(
    fn(base_url) {
      "{\"model\":\"gpt-5\",\"web_search\":\"disabled\",\"base_url\":\"" +
      base_url +
      "\"}"
    },
    cached_models="[{\"model_id\":\"gpt-5\",\"thinking_efforts\":[\"low\"],\"default_effort\":\"low\"}]",
  )
  let fields = ws_body_fields(server.bodies[0])
  assert_eq(
    fields.get("tools"),
    Some(
      Json::array(latest_fixture_tools().map(@responses.tool_to_responses_wire)),
    ),
  )
  assert_false(server.bodies[0].contains("web_search"))
}

///|
#cfg(target="native")
async test "openai_lite_cached_slot_from_live_setting_sends_no_hosted_web_search" {
  // The Lite decision belongs to the discovered/cached model metadata, so the
  // suppression must survive the settings-to-catalog hop, not only a directly
  // constructed port config.
  let server = ws_provider_chat_wire(
    fn(base_url) {
      "{\"model\":\"gpt-5-lite\",\"web_search\":\"live\",\"base_url\":\"" +
      base_url +
      "\"}"
    },
    cached_models="[{\"model_id\":\"gpt-5-lite\",\"use_responses_lite\":true}]",
  )
  let fields = ws_body_fields(server.bodies[0])
  assert_false(fields.contains("tools"))
  assert_false(server.bodies[0].contains("web_search"))
  guard fields.get("input") is Some(Json::Array(input)) &&
    input[0] is Json::Object(additional) else {
    fail("lite additional_tools")
  }
  assert_eq(additional.get("type"), Some(Json::string("additional_tools")))
  assert_eq(
    additional.get("tools"),
    Some(
      Json::array(latest_fixture_tools().map(@responses.tool_to_responses_wire)),
    ),
  )
}
