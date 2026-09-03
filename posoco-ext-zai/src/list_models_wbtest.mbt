///|
fn zai_models_json(text : String) -> Json raise {
  @json.parse(text) catch {
    _ => fail("fixture json")
  }
}

///|
test "parse: OpenAI list envelope, extra fields ignored, duplicates dropped" {
  let ids = parse_zai_models(
    zai_models_json(
      (
        #|{
        #|  "object": "list",
        #|  "data": [
        #|    { "id": "glm-5.3", "object": "model", "owned_by": "zai", "created": 1760000000 },
        #|    { "id": "glm-5.3", "object": "model" },
        #|    { "id": "glm-4.6v", "object": "model", "vendor": { "extra": true } }
        #|  ]
        #|}
      ),
    ),
  )
  debug_inspect(
    ids,
    content=(
      #|["glm-5.3", "glm-4.6v"]
    ),
  )
}

///|
test "parse: object field optional, wrong value rejected" {
  let ids = parse_zai_models(
    zai_models_json(
      (
        #|{
        #|  "data": [ { "id": "glm-5.3" } ]
        #|}
      ),
    ),
  )
  inspect(ids.length(), content="1")
  try
    parse_zai_models(
      zai_models_json(
        (
          #|{
          #|  "object": "page",
          #|  "data": [ { "id": "glm-5.3" } ]
          #|}
        ),
      ),
    )
  catch {
    @posoco.ModelError::ResponseParse(detail) =>
      assert_true(detail.contains("object must be list"))
    _ => fail("expected ResponseParse")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
test "parse: empty data and malformed items are typed failures" {
  let cases : Array[String] = [
    "{\"object\":\"list\",\"data\":[]}", "{\"data\":[{\"id\":\"\"}]}", "{\"data\":[{}]}",
    "{\"data\":[\"glm-5.3\"]}", "{\"data\":{}}", "[{\"id\":\"glm-5.3\"}]",
  ]
  for case in cases {
    try parse_zai_models(zai_models_json(case)) catch {
      @posoco.ModelError::ResponseParse(_) => ()
      _ => fail("expected ResponseParse for \{case}")
    } noraise {
      _ => fail("expected failure for \{case}")
    }
  }
}

///|
test "cached records expand to ids; malformed shapes degrade to None" {
  let ids = parse_cached_zai_models(
    Some(
      zai_models_json(
        (
          #|[
          #|  { "model_id": "glm-5.3", "thinking_efforts": ["off","high"], "default_effort": "high", "context_window": null },
          #|  { "model_id": "glm-5.3" }
          #|]
        ),
      ),
    ),
  )
  debug_inspect(
    ids,
    content=(
      #|Some(["glm-5.3"])
    ),
  )
  debug_inspect(parse_cached_zai_models(None), content="None")
  debug_inspect(parse_cached_zai_models(Some(Json::array([]))), content="None")
  debug_inspect(
    parse_cached_zai_models(Some(zai_models_json("[{\"model_id\":\"\"}]"))),
    content="None",
  )
}

///|
fn zai_catalog_ids(
  ids : Array[String],
  preferred : String,
) -> Array[String] raise @posoco.CompositionError {
  let config = ZaiConfig::for_model(
    "k",
    preferred,
    base_url="https://api.z.ai",
    endpoint_prefix="/api/paas/v4",
  )
  let api_key : &@llm.ApiKeyFactory = ZaiProvider()
  let catalog = zai_model_catalog_from_ids(
    ids,
    config,
    @devkit.ExtContext::default(),
    zai_catalog_identity(),
    api_key,
  )
  let result : Array[String] = []
  for slot in catalog.slots() {
    result.push(slot.model_id)
  }
  result
}

///|
test "catalog from ids keeps the configured model first, preserves order" {
  debug_inspect(
    zai_catalog_ids(["glm-5.2", "glm-5.3", "glm-4.6"], "glm-5.3"),
    content=(
      #|["glm-5.3", "glm-5.2", "glm-4.6"]
    ),
  )
  // A configured model missing from the discovered list is not invented.
  debug_inspect(
    zai_catalog_ids(["glm-5.2", "glm-4.6"], "glm-5.3"),
    content=(
      #|["glm-5.2", "glm-4.6"]
    ),
  )
}

///|
test "catalog from ids assigns generation thinking policy to unknown ids" {
  let ids = zai_catalog_ids(["glm-5.4-turbo", "glm-4.7-flash"], "glm-5.4-turbo")
  inspect(ids.length(), content="2")
  let config5 = ZaiConfig::for_model(
    "k",
    "glm-5.4-turbo",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/paas/v4",
  )
  debug_inspect(
    ZaiModelPort(config5).thinking_state(),
    content="(true, Some(\"high\"))",
  )
  let config4 = ZaiConfig::for_model(
    "k",
    "glm-4.7-flash",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/paas/v4",
  )
  debug_inspect(ZaiModelPort(config4).thinking_state(), content="(true, None)")
  let other = ZaiConfig::for_model(
    "k",
    "embedding-3",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/paas/v4",
  )
  debug_inspect(ZaiModelPort(other).thinking_state(), content="(false, None)")
}

///|
test "catalog from empty ids is a typed composition failure" {
  let config = ZaiConfig::for_model(
    "k",
    "glm-5.3",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/paas/v4",
  )
  let api_key : &@llm.ApiKeyFactory = ZaiProvider()
  try
    zai_model_catalog_from_ids(
      [],
      config,
      @devkit.ExtContext::default(),
      zai_catalog_identity(),
      api_key,
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      inspect(detail, content="models list is empty")
    _ => fail("expected ManifestSchemaError")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
test "factory build expands the catalog from cached model records" {
  let provider = ZaiProvider()
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object({ "api_key": Json::string("k") })),
    cached_models=Some(
      zai_models_json(
        (
          #|[
          #|  { "model_id": "glm-5.2" },
          #|  { "model_id": "glm-5.3" },
          #|  { "model_id": "glm-5.3-air" }
          #|]
        ),
      ),
    ),
  )
  let result = @llm.ProviderFactory::build(provider, source)
  guard result is @llm.ProviderBuildResult::Ready(catalog) else {
    fail("expected Ready")
  }
  // The configured default model (glm-5.3) is ordered first even though the
  // cache listed glm-5.2 first.
  let ids : Array[String] = []
  for slot in catalog.slots() {
    ids.push(slot.model_id)
  }
  debug_inspect(
    ids,
    content=(
      #|["glm-5.3", "glm-5.2", "glm-5.3-air"]
    ),
  )
}
