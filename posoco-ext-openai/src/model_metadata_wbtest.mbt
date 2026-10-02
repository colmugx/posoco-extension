///|
test "openai_lite_discovery_cache_missing_metadata_and_all_rebuild_capabilities" {
  let api = parse_openai_models(
    @json.parse(
      "{\"object\":\"list\",\"data\":[{\"id\":\"future\",\"use_responses_lite\":true},{\"id\":\"future-default\"}]}",
    ),
  )
  assert_true(api[0].use_responses_lite)
  assert_false(api[1].use_responses_lite)
  let base = OpenAIModelPort(OpenAIConfig("test-key", "future"))
  let api_slot = base.model_catalog_from_api_models(api).slots()[0]
  assert_true(api_slot.capabilities.contains("use_responses_lite"))
  let records = @json.parse(
    "[{\"model_id\":\"future\",\"thinking_efforts\":[\"medium\",\"high\"],\"default_effort\":\"medium\",\"context_window\":128000,\"image_in\":true,\"use_responses_lite\":true},{\"model_id\":\"gpt-name-does-not-imply-lite\"}]",
  )
  guard parse_cached_openai_models(Some(records)) is Some(cached) else {
    fail("cache")
  }
  assert_true(cached[0].use_responses_lite)
  assert_false(cached[1].use_responses_lite)
  for oauth in [false, true] {
    let slots = base
      .model_catalog_from_cached_models(cached, chatgpt_mode=oauth)
      .slots()
    assert_true(slots[0].capabilities.contains("use_responses_lite"))
    assert_false(slots[1].capabilities.contains("use_responses_lite"))
    guard slots[0].rebuild_on_effort is Some(effort) &&
      slots[0].rebuild_on_api_key is Some(api_key) else {
      fail("rebuild hooks")
    }
    assert_true(effort("high").capabilities.contains("use_responses_lite"))
    assert_true(
      api_key(@oauth.ApiKeyCredential::ApiKeyCredential(secret="new-test-key")).capabilities.contains(
        "use_responses_lite",
      ),
    )
  }
  assert_true(
    parse_cached_openai_models(
      Some(
        @json.parse(
          "[{\"model_id\":\"future\",\"use_responses_lite\":\"true\"}]",
        ),
      ),
    )
    is None,
  )
  let result = Ok(
    parse_openai_models(
      @json.parse(
        "{\"object\":\"list\",\"data\":[{\"id\":\"future\",\"use_responses_lite\":null}]}",
      ),
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(@posoco.ModelError::ResponseParse(_)))
  let codex = parse_codex_models(
      @json.parse(
        "{\"models\":[{\"slug\":\"future\",\"display_name\":\"Future\",\"supported_reasoning_levels\":[],\"visibility\":\"list\",\"supported_in_api\":true,\"priority\":1,\"use_responses_lite\":true}]}",
      ),
    )[0]
  assert_true(
    base.model_catalog_from_codex_models([codex]).slots()[0].capabilities.contains(
      "use_responses_lite",
    ),
  )
}

///|
#cfg(target="native")
async test "openai_cached_lite_effort_and_key_rebuild_reach_production_compact" {
  let server = CompactLoopback::bind([LatestV2Route])
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      defer server.stop()
      let _ = group.spawn(() => server.serve(), allow_failure=true)
      let base = OpenAIModelPort(
        OpenAIConfig::with_base_url(
          "old-test-key",
          "future",
          "http://127.0.0.1:\{server.server.addr.port()}/v1",
        ),
      )
      guard parse_cached_openai_models(
          Some(
            @json.parse(
              "[{\"model_id\":\"future\",\"thinking_efforts\":[\"medium\",\"high\"],\"default_effort\":\"medium\",\"context_window\":128000,\"use_responses_lite\":true}]",
            ),
          ),
        )
        is Some(cached) else {
        fail("cache")
      }
      let slot = base
        .model_catalog_from_cached_models(cached, chatgpt_mode=false)
        .slots()[0]
      let slot = slot.rebuild_on_effort.unwrap()("high")
      let slot = slot.rebuild_on_api_key.unwrap()(
        @oauth.ApiKeyCredential::ApiKeyCredential(secret="new-test-key"),
      )
      let _ = slot.port.compact(
        compact_loopback_scope(),
        compact_loopback_messages(),
        latest_fixture_tools(),
        { temperature: None, max_output_tokens: None, },
        @posoco.CompactTrigger::Manual,
      )
      assert_eq(slot.port.provider_config().context_window, Some(128000))
    }
  })
  assert_eq(server.requests.length(), 1)
  assert_eq(
    server.requests[0].headers.get("x-openai-internal-codex-responses-lite"),
    Some("true"),
  )
  assert_eq(
    server.requests[0].headers.get("Authorization"),
    Some("Bearer new-test-key"),
  )
  guard @json.parse(server.bodies[0]) is Json::Object(fields) &&
    fields.get("reasoning") is Some(Json::Object(reasoning)) else {
    fail("request")
  }
  assert_eq(reasoning.get("effort"), Some(Json::string("high")))
  assert_false(fields.contains("tools"))
  assert_true(fields["input"].stringify().contains("current_tool"))
}
