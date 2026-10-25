///|
/// `/decision` command tests: the listing (with active marker and explicit
/// off-state hints), the switch, and the kind separation from `/model`.

///|
fn decision_test_router() -> RouterModelPort raise @posoco.CompositionError {
  let chat_port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let judge_port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let judge_second : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  RouterModelPort(slots=[
    ModelSlot::ModelSlot(
      id="chat",
      label="Chat",
      provider_id="provider-a",
      model_id="model-a",
      port=chat_port,
    ),
    ModelSlot::ModelSlot(
      id="judge",
      label="Judge",
      provider_id="provider-b",
      model_id="judge-b",
      port=judge_port,
      kind=ModelKind::Decision,
      decision_port=Some(@posoco.ScriptedDecisionPort([])),
    ),
    ModelSlot::ModelSlot(
      id="judge-2",
      label="Judge Two",
      provider_id="provider-c",
      model_id="judge-c",
      port=judge_second,
      kind=ModelKind::Decision,
      decision_port=Some(@posoco.ScriptedDecisionPort([])),
    ),
  ])
}

///|
async test "decision command lists decision slots with the active marker" {
  let router = decision_test_router()
  router.switch_decision_slot("judge") catch {
    _ => fail("unexpected decision switch failure")
  }
  let outcome = router.invoke("decision", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("active: judge"))
      guard structured is Some(Json::Array(entries)) else {
        fail("expected structured decision slot catalog")
      }
      assert_eq(entries.length(), 2)
      guard entries[0] is Json::Object(fields) else {
        fail("expected decision slot object")
      }
      assert_eq(fields.get("id"), Some(Json::string("judge")))
      assert_eq(fields.get("provider"), Some(Json::string("provider-b")))
      assert_eq(fields.get("model"), Some(Json::string("judge-b")))
      assert_eq(fields.get("active"), Some(Json::boolean(true)))
      guard entries[1] is Json::Object(second) else {
        fail("expected second decision slot object")
      }
      assert_eq(second.get("active"), Some(Json::boolean(false)))
    }
    _ => fail("expected successful decision listing")
  }
}

///|
async test "decision command hints the unconfigured selection in the listing" {
  // Fresh router: decision slots exist but nothing is selected.
  let router = decision_test_router()
  match router.invoke("decision", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("no decision model selected"))
      guard structured is Some(Json::Array(entries)) else {
        fail("expected structured decision slot catalog")
      }
      assert_eq(entries.length(), 2)
    }
    _ => fail("expected successful decision listing")
  }
  // A pending persisted id names the missing slot instead of a silent off.
  let chat_port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let judge_port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let pending = RouterModelPort(
    slots=[
      ModelSlot::ModelSlot(
        id="chat",
        label="Chat",
        provider_id="provider-a",
        model_id="model-a",
        port=chat_port,
      ),
      ModelSlot::ModelSlot(
        id="judge",
        label="Judge",
        provider_id="provider-b",
        model_id="judge-b",
        port=judge_port,
        kind=ModelKind::Decision,
        decision_port=Some(@posoco.ScriptedDecisionPort([])),
      ),
    ],
    default_decision_slot_id="gone/judge",
    allow_missing_decision_default=true,
  )
  match pending.invoke("decision", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_true(feedback.contains("gone/judge"))
      assert_true(feedback.contains("not configured"))
    }
    _ => fail("expected successful decision listing")
  }
}

///|
async test "decision command switches the active decision model" {
  let router = decision_test_router()
  let args = Json::object(Map::from_array([("slot", Json::string("judge-2"))]))
  let outcome = router.invoke("decision", args)
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  assert_eq(router.active_decision_slot_id(), "judge-2")
  assert_eq(router.active_slot_id(), "chat")
}

///|
async test "decision command accepts the positional slot a host parser produces" {
  let router = decision_test_router()
  let outcome = router.invoke("decision", Json::string("judge"))
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  assert_eq(router.active_decision_slot_id(), "judge")
}

///|
async test "decision command rejects chat and unknown slots" {
  let router = decision_test_router()
  match
    router.invoke(
      "decision",
      Json::object(Map::from_array([("slot", Json::string("chat"))])),
    ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(
        reason.contains("slot is a chat model; switch it with /model"),
      )
    _ => fail("a chat slot must never become the decision target")
  }
  match
    router.invoke(
      "decision",
      Json::object(Map::from_array([("slot", Json::string("ghost"))])),
    ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("unknown decision model slot: ghost"))
    _ => fail("expected unknown decision slot failure")
  }
  // A rejected switch leaves the previous state untouched.
  assert_eq(router.active_decision_slot_id(), "")
}

///|
async test "model command hides decision slots and refuses to switch to one" {
  let router = decision_test_router()
  match router.invoke("model", Json::null()) {
    @posoco.CommandOutcome::Success(structured~, ..) => {
      guard structured is Some(Json::Array(entries)) else {
        fail("expected structured slot catalog")
      }
      assert_eq(entries.length(), 1)
      guard entries[0] is Json::Object(fields) else {
        fail("expected slot catalog object")
      }
      assert_eq(fields.get("id"), Some(Json::string("chat")))
    }
    _ => fail("expected successful model listing")
  }
  match
    router.invoke(
      "model",
      Json::object(Map::from_array([("slot", Json::string("judge"))])),
    ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(
        reason.contains("slot is a decision model; switch it with /decision"),
      )
    _ => fail("the conversation selection must not cross kinds")
  }
  assert_eq(router.active_slot_id(), "chat")
}

///|
async test "model command choices and picker exclude decision slots" {
  let router = decision_test_router()
  let defs = router.commands()
  match defs[0].params[0].choices {
    Some(choices) => assert_eq(choices, ["quick-pick", "chat"])
    None => fail("expected slot choices")
  }
  match defs[4].params[0].choices {
    Some(choices) => assert_eq(choices, ["judge", "judge-2"])
    None => fail("expected decision slot choices")
  }
  // The Board picker projection stays a chat-selection surface too.
  let picker = router.picker_catalog_json()
  assert_eq(picker.length(), 1)
  guard picker[0] is Json::Object(fields) else {
    fail("expected picker entry object")
  }
  assert_eq(fields.get("id"), Some(Json::string("chat")))
  // Same for the manager-neutral metadata projection.
  assert_eq(router.list_models().length(), 1)
  assert_eq(router.list_models()[0].model_id, "chat")
}

///|
async test "decision command reports an empty catalog with the off hint" {
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let router = RouterModelPort(slots=[
    ModelSlot::ModelSlot(
      id="chat",
      label="Chat",
      provider_id="provider-a",
      model_id="model-a",
      port~,
    ),
  ])
  match router.invoke("decision", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("No decision model slots are configured"))
      assert_true(feedback.contains("decision is off"))
      guard structured is Some(Json::Array(entries)) else {
        fail("expected structured decision slot catalog")
      }
      assert_eq(entries.length(), 0)
    }
    _ => fail("expected successful decision listing")
  }
}
