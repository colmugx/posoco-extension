///
/// Pure list-models schema tests. No network calls are made here.

///|
test "DeepSeek models parser preserves order and provider effort policy" {
  let payload : Json = {
    "object": "list",
    "data": [
      { "id": "deepseek-v4-pro", "object": "model", "owned_by": "deepseek" },
      { "id": "deepseek-chat", "object": "model", "owned_by": "deepseek" },
    ],
  }
  let models = parse_deepseek_models(payload)
  assert_eq(models.length(), 2)
  assert_eq(models[0].id, "deepseek-v4-pro")
  assert_eq(models[0].thinking_efforts, [
    "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
  ])
  assert_eq(models[0].default_effort, Some("minimal"))
  assert_eq(models[1].thinking_efforts, [])
  assert_eq(models[1].default_effort, None)
}

///|
test "DeepSeek models parser prefers a declared reasoning_effort descriptor" {
  let payload : Json = {
    "object": "list",
    "data": [
      {
        "id": "deepseek-v4-pro",
        "object": "model",
        "owned_by": "deepseek",
        "reasoning_effort": ["medium", "ultra"],
      },
      {
        "id": "deepseek-v4-flash",
        "object": "model",
        "owned_by": "deepseek",
        "reasoning_effort": [],
      },
      {
        "id": "deepseek-v4-pro-dup",
        "object": "model",
        "owned_by": "deepseek",
        "reasoning_effort": "low",
      },
    ],
  }
  let models = parse_deepseek_models(payload)
  // A well-formed array wins over the provider policy, even off-policy.
  assert_eq(models[0].thinking_efforts, ["medium", "ultra"])
  assert_eq(models[0].default_effort, Some("medium"))
  // An explicitly empty array declares a non-reasoning model.
  assert_eq(models[1].thinking_efforts, [])
  // A wrong-shaped descriptor degrades to the provider policy, not a failure.
  assert_eq(models[2].thinking_efforts, [
    "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
  ])
}

///|
test "DeepSeek models parser rejects malformed item schema" {
  let payload : Json = {
    "object": "list",
    "data": [
      { "id": "deepseek-v4-pro", "object": "wrong", "owned_by": "deepseek" },
    ],
  }
  let result = Ok(parse_deepseek_models(payload)) catch { err => Err(err) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("object must be model"))
    _ => fail("expected typed DeepSeek model schema failure")
  }
}

///|
test "DeepSeek models parser rejects a non-list envelope" {
  let payload : Json = { "object": "not-list", "data": [] }
  let result = Ok(parse_deepseek_models(payload)) catch { err => Err(err) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("object must be list"))
    _ => fail("expected typed DeepSeek envelope failure")
  }
}

///|
async test "DeepSeek refresh rejects an unknown effort as composition error" {
  let provider = DeepSeekProvider()
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      @json.parse("{\"api_key\":\"key\",\"reasoning_effort\":\"unknown\"}"),
    ),
    provider_credential=None,
  )
  let result = Ok(provider.refresh(source)) catch { err => Err(err) }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("unsupported reasoning_effort"))
    _ => fail("expected typed DeepSeek effort composition failure")
  }
}

///|
test "DeepSeek refreshed catalog keeps configured model first" {
  let config = DeepSeekConfig("key", model="deepseek-chat")
  let port = DeepSeekModelPort(config)
  let models : Array[DeepSeekModelInfo] = [
    DeepSeekModelInfo::{
      id: "deepseek-v4-pro",
      owned_by: "deepseek",
      thinking_efforts: ["high", "max"],
      default_effort: Some("high"),
    },
    DeepSeekModelInfo::{
      id: "deepseek-chat",
      owned_by: "deepseek",
      thinking_efforts: [],
      default_effort: None,
    },
  ]
  let catalog = port.model_catalog_from_models(models)
  let slots = catalog.slots()
  // The catalog mirrors the fetched list; only the preferred model reorders.
  assert_eq(slots.length(), 2)
  assert_eq(slots[0].model_id, "deepseek-chat")
  assert_eq(slots[1].model_id, "deepseek-v4-pro")
  match slots[0].rebuild_on_effort {
    None => ()
    Some(_) =>
      fail("non-reasoning DeepSeek slot must not expose effort rebuild")
  }
  assert_eq(slots[1].default_effort, Some("high"))
  match slots[1].rebuild_on_effort {
    Some(rebuild) => {
      let changed = rebuild("max")
      // default_effort tracks the slot's current effort (derived from the
      // rebuilt config), so the picker highlights the actual selection.
      assert_eq(changed.default_effort, Some("max"))
    }
    None => fail("expected DeepSeek effort rebuild hook")
  }
}
