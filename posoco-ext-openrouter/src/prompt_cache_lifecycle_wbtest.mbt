///|
test "OpenRouter rebuilt ports share learned prompt-cache rejection" {
  let state : Ref[Bool] = Ref(false)
  let config = OpenRouterConfig("key", model="m", send_prompt_cache_key=true)
  let first = openrouter_model_port_with_prompt_cache_rejection_state(config, state)
  assert_eq(
    first.prompt_cache_key(cache_scope("session-1")),
    Some("posoco-session-1"),
  )

  first.learn_cache_key_rejection(
    BodyText("Unsupported parameter: prompt_cache_key"),
  )
  assert_true(state.val)

  let rebuilt = openrouter_model_port_with_prompt_cache_rejection_state(
    { ..config, api_key: "rotated-key", },
    state,
  )
  assert_eq(rebuilt.prompt_cache_key(cache_scope("session-1")), None)
}

///|
test "OpenRouter provider instances isolate prompt-cache rejection state" {
  let first = OpenRouterProvider()
  let second = OpenRouterProvider()
  first.prompt_cache_key_rejection_state.val = true
  assert_true(first.prompt_cache_key_rejection_state.val)
  assert_false(second.prompt_cache_key_rejection_state.val)
}

///|
test "OpenRouter prompt-cache setting is strict boolean and defaults off" {
  let absent = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::empty_object()),
  )
  assert_false(openrouter_setting_bool(absent, "send_prompt_cache_key"))

  let enabled = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([("send_prompt_cache_key", Json::True)]),
      ),
    ),
  )
  assert_true(openrouter_setting_bool(enabled, "send_prompt_cache_key"))

  let invalid = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([("send_prompt_cache_key", Json::string("true"))]),
      ),
    ),
  )
  let result = Ok(openrouter_setting_bool(invalid, "send_prompt_cache_key")) catch {
    err => Err(err)
  }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("must be a boolean"))
    _ => fail("non-boolean prompt-cache setting must fail composition")
  }
}
