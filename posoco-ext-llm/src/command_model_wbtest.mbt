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
  assert_eq(defs.length(), 2)
  assert_eq(defs[0].id, "model")
  assert_true(defs[0].ctype is @posoco.CommandType::Select)
  match defs[0].params[0].choices {
    Some(choices) => assert_eq(choices, ["first", "second"])
    None => fail("expected slot choices")
  }
  assert_eq(defs[1].id, "login")
  assert_true(defs[1].params[0].choices is None)
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
