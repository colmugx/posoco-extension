///|
test "DeepSeek factory propagates explicit capacity through discovery and rebuilds" {
  let records : Json = [
    { "model_id": "deepseek-flash", "context_window": 1000000 },
    { "model_id": "deepseek-pro", "context_window": 128000 },
  ]
  let source = @llm.ProviderConfigSource(
    settings=Some({
      "api_key": "test-key",
      "model": "deepseek-flash",
      "context_window": 65000,
    }),
    cached_models=Some(records),
  )
  guard DeepSeekProvider().build(source)
    is @llm.ProviderBuildResult::Ready(catalog) else {
    fail("expected catalog")
  }
  let slots = catalog.slots()
  assert_eq(slots[0].context_window, Some(65000))
  assert_eq(slots[0].context_window_source, "configured")
  assert_eq(slots[0].port.provider_config().context_window, Some(65000))
  assert_eq(slots[1].context_window, Some(128000))
  assert_eq(slots[1].context_window_source, "provider_cache")
  let credential = @oauth.ApiKeyCredential(secret="replacement")
  for slot in slots {
    guard slot.rebuild_on_api_key is Some(rebuild_key) else {
      fail("missing key hook")
    }
    guard slot.rebuild_on_effort is Some(rebuild_effort) else {
      fail("missing effort hook")
    }
    assert_eq(rebuild_key(credential).context_window, slot.context_window)
    assert_eq(rebuild_effort("max").context_window, slot.context_window)
  }
  let router = @llm.RouterModelPort::from_catalogs([catalog])
  assert_eq(router.provider_config().context_window, Some(65000))
  router.switch_slot("deepseek/deepseek-pro")
  assert_eq(router.provider_config().context_window, Some(128000))
}

///|
test "DeepSeek rejects invalid explicit capacity instead of silently falling back" {
  for
    value in [
      Json::number(0.0),
      Json::number(-1.0),
      Json::number(1.5),
      Json::number(2147483648.0),
      Json::string("500000"),
    ] {
    let source = @llm.ProviderConfigSource(
      settings=Some({ "api_key": "test-key", "context_window": value }),
    )
    try DeepSeekProvider().build(source) catch {
      @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
        assert_eq(manifest_id, "posoco_ext_deepseek")
        assert_true(detail.contains("context_window"))
      }
      err => raise err
    } noraise {
      _ => fail("expected invalid capacity rejection")
    }
  }
}

///|
test "DeepSeek provider settings propagate ceiling to all model slots" {
  let records : Json = [
    { "model_id": "deepseek-flash", "context_window": 1000000 },
    { "model_id": "deepseek-pro", "context_window": 128000 },
  ]
  let source = @llm.ProviderConfigSource(
    settings=Some({
      "api_key": "test-key",
      "max_reasoning_chars": 120000,
    }),
    cached_models=Some(records),
  )
  guard DeepSeekProvider().build(source)
    is @llm.ProviderBuildResult::Ready(catalog) else {
    fail("expected a ready DeepSeek catalog")
  }
  for slot in catalog.slots() {
    guard slot.port is DeepSeekModelPort(config~, ..) else {
      fail("expected DeepSeek port")
    }
    assert_eq(config.max_reasoning_chars, Some(120000))
    guard slot.rebuild_on_effort is Some(rebuild_effort) else {
      fail("missing effort hook")
    }
    guard rebuild_effort("low").port is DeepSeekModelPort(config~, ..) else {
      fail("expected rebuilt DeepSeek port")
    }
    assert_eq(config.max_reasoning_chars, Some(120000))
  }
}

///|
test "DeepSeek generic provider rejects malformed reasoning ceilings" {
  for value in [
    Json::number(0.0),
    Json::number(-1.0),
    Json::number(1.5),
    Json::number(2147483648.0),
    Json::string("5000"),
    Json::boolean(true),
  ] {
    let source = @llm.ProviderConfigSource(
      settings=Some({
        "api_key": "test-key",
        "max_reasoning_chars": value,
      }),
    )
    try DeepSeekProvider().build(source) catch {
      @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
        assert_eq(manifest_id, "posoco_ext_deepseek")
        assert_true(detail.contains("max_reasoning_chars"))
      }
      err => raise err
    } noraise {
      _ => fail("expected invalid reasoning ceiling rejection")
    }
  }
}
