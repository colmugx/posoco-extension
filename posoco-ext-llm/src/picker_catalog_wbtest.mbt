///|
/// Picker catalog: the router projects its slots into the shape non-command
/// surfaces (the Board ticket picker) read. `/model` keeps its own richer
/// catalog; these tests pin the reduced shape and its provider facts.

///|
fn picker_test_slot(
  id : String,
  provider_id : String,
  model_id : String,
  efforts : Array[String],
) -> ModelSlot {
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: efforts.copy(),
  }
  ModelSlot::ModelSlot(
    id~,
    label=id,
    provider_id~,
    model_id~,
    port~,
    thinking_efforts=efforts.copy(),
  )
}

///|
test "picker catalog projects router slots into the shared picker shape" {
  let plain = picker_test_slot("openai/gpt", "openai", "gpt", [])
  let effortful = {
    ..picker_test_slot("openai/o-reasoning", "openai", "o-reasoning", [
      "low", "high",
    ]),
    label: "OpenAI o (reasoning)",
    default_effort: Some("high"),
    context_window: Some(400_000),
    context_window_source: "configured",
    capabilities: ["tool_use", "image_in"],
  }
  let router = RouterModelPort(
    slots=[plain, effortful],
    default_slot_id="openai/gpt",
  )
  let entries = router.picker_catalog_json()
  assert_eq(entries.length(), 2)
  guard entries[1] is Json::Object(fields) else {
    fail("every picker entry must be an object")
  }
  // Exactly the picker shape: no active/quota/pricing/group extras leak.
  assert_eq(fields.keys().count(), 8)
  assert_eq(fields.get("id"), Some(Json::string("openai/o-reasoning")))
  assert_eq(fields.get("label"), Some(Json::string("OpenAI o (reasoning)")))
  assert_eq(fields.get("provider"), Some(Json::string("openai")))
  assert_eq(fields.get("model"), Some(Json::string("o-reasoning")))
  assert_eq(
    fields.get("efforts"),
    Some(Json::array([Json::string("low"), Json::string("high")])),
  )
  assert_eq(fields.get("default_effort"), Some(Json::string("high")))
  assert_eq(fields.get("context_window"), Some(Json::number(400_000.0)))
  assert_eq(
    fields.get("capabilities"),
    Some(Json::array([Json::string("tool_use"), Json::string("image_in")])),
  )
}

///|
test "picker catalog states an empty effort ladder and an unknown window honestly" {
  let plain = picker_test_slot("openai/gpt", "openai", "gpt", [])
  let router = RouterModelPort(slots=[plain], default_slot_id="openai/gpt")
  let entries = router.picker_catalog_json()
  assert_eq(entries.length(), 1)
  guard entries[0] is Json::Object(fields) else {
    fail("every picker entry must be an object")
  }
  // No advertised effort means no override is legal; null (never a copy of
  // another model's ladder) states that.
  assert_eq(fields.get("efforts"), Some(Json::array([])))
  assert_true(fields.get("default_effort") is Some(Json::Null))
  assert_eq(fields.get("capabilities"), Some(Json::array([])))
  // The window is a positive number: the same resolved reading `/model`
  // reports, never a null hole a picker has to guess around.
  guard fields.get("context_window") is Some(Json::Number(window, ..)) else {
    fail("context_window must be a number")
  }
  assert_true(window > 0.0)
}
