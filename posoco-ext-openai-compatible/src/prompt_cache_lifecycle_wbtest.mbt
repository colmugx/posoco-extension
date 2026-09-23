///|
test "OpenAI-compatible rebuilt ports share learned prompt-cache rejection" {
  let state : Ref[Bool] = Ref(false)
  let config = OpenAICompatibleConfig(
    "key",
    base_url="https://example.test/v1",
    model="model-a",
    send_prompt_cache_key=true,
  )
  let first = oai_compat_model_port_with_prompt_cache_rejection_state(
    "custom-a", config, state,
  )
  assert_false(first.prompt_cache_key_rejected_now())

  first.learn_prompt_cache_key_rejection(
    "Unsupported parameter: prompt_cache_key",
  )
  assert_true(state.val)

  let rebuilt = oai_compat_model_port_with_prompt_cache_rejection_state(
    "custom-a",
    { ..config, api_key: "rotated-key", },
    state,
  )
  assert_true(rebuilt.prompt_cache_key_rejected_now())
}

///|
test "OpenAI-compatible provider instances isolate rejection state" {
  let first = OpenAICompatibleProvider("custom-a")
  let second = OpenAICompatibleProvider("custom-b")
  first.prompt_cache_key_rejection_state.val = true
  assert_true(first.prompt_cache_key_rejection_state.val)
  assert_false(second.prompt_cache_key_rejection_state.val)
}

///|
test "OpenAI-compatible prompt-cache setting is strict boolean and defaults off" {
  let absent = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::empty_object()),
  )
  assert_false(oai_compat_setting_bool(absent, "send_prompt_cache_key"))

  let enabled = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([("send_prompt_cache_key", Json::boolean(true))]),
      ),
    ),
  )
  assert_true(oai_compat_setting_bool(enabled, "send_prompt_cache_key"))

  let invalid = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([("send_prompt_cache_key", Json::string("true"))]),
      ),
    ),
  )
  let result = Ok(oai_compat_setting_bool(invalid, "send_prompt_cache_key")) catch {
    err => Err(err)
  }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("must be a boolean"))
    _ => fail("non-boolean prompt-cache setting must fail composition")
  }
}

///|
test "config selection carries provider-level prompt-cache policy" {
  let config = oai_compat_config_from_selection(
    "key",
    base_url="https://example.test/v1",
    model="model-a",
    endpoint_prefix="",
    declared_efforts=[],
    send_prompt_cache_key=true,
  ) catch {
    err => abort("fixture config must be valid: " + err.to_string())
  }
  assert_true(config.send_prompt_cache_key)
}
