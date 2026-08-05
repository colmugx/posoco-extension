///|
fn command_test_router() -> RouterModelPort raise @posoco.CompositionError {
  let first_port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let second_port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  RouterModelPort::new(slots=[
    ModelSlot::ModelSlot(
      id="first",
      label="First",
      provider_id="provider-a",
      model_id="model-a",
      port=first_port,
    ),
    ModelSlot::ModelSlot(
      id="second",
      label="Second",
      provider_id="provider-b",
      model_id="model-b",
      port=second_port,
    ),
  ])
}

///|
async test "model command lists all slots" {
  let router = command_test_router()
  let outcome = router.invoke("model", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      ignore(feedback)
      ignore(ui_hint)
      match structured {
        Some(Json::Array(entries)) => {
          assert_eq(entries.length(), 2)
          match entries[0] {
            Json::Object(fields) =>
              match fields.get("active") {
                Some(Json::True) => ()
                _ => fail("first slot should be active")
              }
            _ => fail("expected slot catalog object")
          }
        }
        _ => fail("expected structured slot catalog")
      }
    }
    _ => fail("expected successful model listing")
  }
}

///|
async test "model command switches the active slot" {
  let router = command_test_router()
  let args = Json::object(Map::from_array([("slot", Json::string("second"))]))
  let outcome = router.invoke("model", args)
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  assert_eq(router.active_slot_id(), "second")
}

///|
async test "model command reports an unknown slot" {
  let router = command_test_router()
  let args = Json::object(Map::from_array([("slot", Json::string("missing"))]))
  let outcome = router.invoke("model", args)
  match outcome {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("unknown model slot: missing"))
    _ => fail("expected unknown slot failure")
  }
}

///|
async test "model command declares dynamic slot choices" {
  let router = command_test_router()
  let defs = router.commands()
  assert_eq(defs.length(), 3)
  assert_eq(defs[0].id, "model")
  assert_true(defs[0].ctype is @posoco.CommandType::Select)
  match defs[0].params[0].choices {
    Some(choices) => assert_eq(choices, ["first", "second"])
    None => fail("expected slot choices")
  }
  assert_eq(defs[1].id, "login")
  assert_true(defs[1].params[0].choices is None)
  assert_eq(defs[2].id, "effort")
  assert_true(defs[2].ctype is @posoco.CommandType::Select)
  match defs[2].params[0].choices {
    Some(choices) => assert_eq(choices, [])
    None => fail("expected effort choices")
  }
}

///|
async test "model command validates and applies provider effort" {
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let slot = ModelSlot::ModelSlot(
    id="effort-slot",
    label="Effort",
    provider_id="provider",
    model_id="model",
    port~,
    thinking_efforts=["low", "high"],
    rebuild_on_effort=Some(fn(effort) {
      let rebuilt : &@posoco.ModelPort = RouterTestPort::{
        reasoning_effort_values: [effort],
      }
      ModelSlot::ModelSlot(
        id="effort-slot",
        label="Effort",
        provider_id="provider",
        model_id="model",
        port=rebuilt,
        thinking_efforts=["low", "high"],
        rebuild_on_effort=Some(fn(_) {
          abort("nested test rebuild is not expected")
        }),
      )
    }),
  )
  let router = RouterModelPort::new(slots=[slot])
  let outcome = router.invoke(
    "model",
    Json::object(
      Map::from_array([
        ("slot", Json::string("effort-slot")),
        ("effort", Json::string("high")),
      ]),
    ),
  )
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  assert_eq(router.active_effort(), Some("high"))
  let invalid = router.invoke(
    "model",
    Json::object(
      Map::from_array([
        ("slot", Json::string("effort-slot")),
        ("effort", Json::string("max")),
      ]),
    ),
  )
  assert_true(invalid is @posoco.CommandOutcome::Failure(..))
}

///|
/// Router with one effort-capable slot. The rebuild hook preserves the slot's
/// effort metadata and records the requested effort on the replacement port.
fn effort_test_router() -> RouterModelPort raise @posoco.CompositionError {
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  RouterModelPort::new(slots=[
    ModelSlot::ModelSlot(
      id="effort-slot",
      label="Effort",
      provider_id="provider",
      model_id="model",
      port~,
      thinking_efforts=["low", "high"],
      default_effort=Some("low"),
      rebuild_on_effort=Some(fn(effort) {
        let rebuilt : &@posoco.ModelPort = RouterTestPort::{
          reasoning_effort_values: [effort],
        }
        ModelSlot::ModelSlot(
          id="effort-slot",
          label="Effort",
          provider_id="provider",
          model_id="model",
          port=rebuilt,
          thinking_efforts=["low", "high"],
          default_effort=Some("low"),
          rebuild_on_effort=Some(fn(_) {
            abort("nested test rebuild is not expected")
          }),
        )
      }),
    ),
  ])
}

///|
async test "effort command reports the current effort" {
  let router = effort_test_router()
  let outcome = router.invoke("effort", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      assert_true(feedback.contains("current effort: low"))
      assert_true(ui_hint is Some(@posoco.UiHint::None))
      match structured {
        Some(Json::Array(entries)) =>
          match entries[0] {
            Json::Object(fields) => {
              match fields.get("default_effort") {
                Some(Json::String(value)) => assert_eq(value, "low")
                _ => fail("expected default_effort in slot catalog")
              }
              match fields.get("active_effort") {
                Some(Json::Null) => ()
                _ => fail("active_effort should be null before selection")
              }
            }
            _ => fail("expected slot catalog object")
          }
        _ => fail("expected structured slot catalog")
      }
    }
    _ => fail("expected successful effort query")
  }
}

///|
async test "effort command applies provider effort" {
  let router = effort_test_router()
  let outcome = router.invoke(
    "effort",
    Json::object(Map::from_array([("_positional", Json::string("high"))])),
  )
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  assert_eq(router.active_effort(), Some("high"))
  let query = router.invoke("effort", Json::null())
  match query {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("current effort: high"))
    _ => fail("expected successful effort query")
  }
  let invalid = router.invoke(
    "effort",
    Json::object(Map::from_array([("effort", Json::string("max"))])),
  )
  match invalid {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("unsupported effort"))
    _ => fail("expected unsupported effort failure")
  }
}

///|
async test "effort command fails for slots without effort selection" {
  let router = command_test_router()
  let outcome = router.invoke(
    "effort",
    Json::object(Map::from_array([("_positional", Json::string("high"))])),
  )
  match outcome {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("does not support effort selection"))
    _ => fail("expected no-effort-selection failure")
  }
  let query = router.invoke("effort", Json::null())
  match query {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("no effort selection"))
    _ => fail("expected successful effort query")
  }
}

///|
async test "model command emits the provider-declared display group" {
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let grouped = ModelSlot::ModelSlot(
    id="qwen/qwen-plus",
    label="qwen / qwen-plus",
    provider_id="qwen",
    model_id="qwen-plus",
    port~,
    display_group=Some("custom"),
  )
  let ungrouped = ModelSlot::ModelSlot(
    id="deepseek/deepseek-v4-flash",
    label="DeepSeek / deepseek-v4-flash",
    provider_id="deepseek",
    model_id="deepseek-v4-flash",
    port~,
  )
  let router = RouterModelPort::new(slots=[grouped, ungrouped])
  let outcome = router.invoke("model", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(structured~, ..) =>
      match structured {
        Some(Json::Array(entries)) => {
          guard entries[0] is Json::Object(first) else {
            fail("expected slot catalog object")
          }
          match first.get("group") {
            Some(Json::String("custom")) => ()
            _ => fail("expected the declared display group")
          }
          // The operational provider id stays intact for credentials/routing.
          match first.get("provider") {
            Some(Json::String("qwen")) => ()
            _ => fail("expected the real provider id alongside the group")
          }
          guard entries[1] is Json::Object(second) else {
            fail("expected slot catalog object")
          }
          match second.get("group") {
            Some(Json::Null) => ()
            _ => fail("ungrouped slots must emit a null group")
          }
        }
        _ => fail("expected structured slot catalog")
      }
    _ => fail("expected successful model catalog")
  }
}
