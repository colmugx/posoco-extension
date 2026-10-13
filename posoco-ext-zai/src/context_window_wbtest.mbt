///|
test "Zai cached windows survive key and effort rebuilds without overriding settings" {
  let source = @llm.ProviderConfigSource(
    settings=Some({
      "api_key": "test-key",
      "model": "glm-5.3",
      "context_window": 65000,
    }),
    cached_models=Some([
      { "model_id": "glm-5.3", "context_window": 1000000 },
      {
        "model_id": "glm-5.2",
        "context_window": 128000,
        "context_window_source": "provider",
        "metadata_provider_id": "zai",
      },
    ]),
  )
  guard ZaiProvider().build(source) is @llm.ProviderBuildResult::Ready(catalog) else {
    fail("expected catalog")
  }
  let slots = catalog.slots()
  assert_eq(slots[0].context_window, Some(65000))
  assert_eq(slots[0].context_window_source, "configured")
  assert_eq(slots[1].context_window, Some(128000))
  assert_eq(slots[1].context_window_source, "provider_cache")
  guard slots[1].rebuild_on_effort is Some(rebuild_effort) else {
    fail("missing effort hook")
  }
  assert_eq(rebuild_effort("max").context_window, Some(128000))
  guard slots[1].rebuild_on_api_key is Some(rebuild_key) else {
    fail("missing key hook")
  }
  assert_eq(
    rebuild_key(@oauth.ApiKeyCredential(secret="new-key")).context_window,
    Some(128000),
  )
  let domestic = rebuild_key(
    @oauth.ApiKeyCredential(
      secret="new-key",
      metadata=Map::from_array([("platform", "bigmodel")]),
    ),
  )
  assert_eq(domestic.metadata_provider_id, Some("zhipuai"))
  assert_eq(domestic.context_window, None)
}

///|
test "Zai serving metadata identities isolate direct coding domestic and custom endpoints" {
  let source = @llm.ProviderConfigSource(
    settings=Some({ "api_key": "test-key", "platform": "bigmodel" }),
  )
  guard ZaiProvider().build(source) is @llm.ProviderBuildResult::Ready(catalog) else {
    fail("expected catalog")
  }
  assert_eq(catalog.slots()[0].metadata_provider_id, Some("zhipuai"))
  let custom = @llm.ProviderConfigSource(
    settings=Some({ "api_key": "test-key", "base_url": "http://localhost:1234" }),
  )
  guard ZaiProvider().build(custom)
    is @llm.ProviderBuildResult::Ready(custom_catalog) else {
    fail("expected catalog")
  }
  assert_eq(custom_catalog.slots()[0].metadata_provider_id, Some(""))
  try
    zai_setting_context_window(
      @llm.ProviderConfigSource(
        settings=Some({ "context_window": 2147483648.0 }),
      ),
      manifest_id="test",
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("Int range"))
    err => raise err
  } noraise {
    _ => fail("expected overflow rejection")
  }
}
