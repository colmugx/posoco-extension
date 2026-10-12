///|
test "Coding Plan restores per-model cached capacity and preserves configured override" {
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
        "metadata_provider_id": "zai-coding-plan",
      },
    ]),
  )
  guard ZaiCodingPlanProvider().build(source)
    is @llm.ProviderBuildResult::Ready(catalog) else {
    fail("expected catalog")
  }
  assert_eq(catalog.slots()[0].context_window, Some(65000))
  assert_eq(catalog.slots()[0].context_window_source, "configured")
  assert_eq(catalog.slots()[0].metadata_provider_id, Some("zai-coding-plan"))
  for slot in catalog.slots() {
    if slot.model_id == "glm-5.2" {
      assert_eq(slot.context_window, Some(128000))
      guard slot.rebuild_on_api_key is Some(rebuild) else {
        fail("missing key hook")
      }
      assert_eq(
        rebuild(@oauth.ApiKeyCredential(secret="new-key")).context_window,
        Some(128000),
      )
      guard slot.rebuild_on_effort is Some(effort) else {
        fail("missing effort hook")
      }
      assert_eq(effort("max").context_window, Some(128000))
    }
  }
  let router = @llm.RouterModelPort::from_catalogs([catalog])
  router.switch_slot("zai-coding-plan/glm-5.2")
  assert_eq(router.provider_config().context_window, Some(128000))
}
