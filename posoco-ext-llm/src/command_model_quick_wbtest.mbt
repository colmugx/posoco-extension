///|
/// Scripted quota source for quick-pick tests: plays one fixed result on
/// every read and counts the calls.
struct QuickPickQuotaSource {
  result : Result[Array[@devkit.QuotaReading], String]
  mut calls : Int
}

///|
pub impl @devkit.QuotaSource for QuickPickQuotaSource with fn read(
  self : QuickPickQuotaSource,
) -> Result[Array[@devkit.QuotaReading], String] {
  self.calls = self.calls + 1
  self.result
}

///|
fn quick_pick_slot(id : String, provider_id : String) -> ModelSlot {
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  ModelSlot::ModelSlot(id~, label=id, provider_id~, model_id="model-x", port~)
}

///|
fn quick_pick_args() -> Json {
  Json::object(Map::from_array([("slot", Json::string("quick-pick"))]))
}

///|
/// Fields of the slot-catalog entry with `slot_id`, or None when absent.
fn quick_pick_entry(structured : Json?, slot_id : String) -> Map[String, Json]? {
  match structured {
    Some(Json::Array(entries)) =>
      for entry in entries {
        match entry {
          Json::Object(fields) =>
            match fields.get("id") {
              Some(Json::String(id)) => if id == slot_id { return Some(fields) }
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  None
}

///|
async test "quick-pick aggregates readings for slot-contributing providers" {
  let source : &@devkit.QuotaSource = QuickPickQuotaSource::{
    result: Ok([
      @devkit.QuotaReading::{
        window: "5h",
        used_percent: Some(25.0),
        amount: None,
        available: None,
        reset_at_ms: None,
        fetched_at_ms: 1L,
      },
      @devkit.QuotaReading::{
        window: "weekly",
        used_percent: Some(60.0),
        amount: None,
        available: None,
        reset_at_ms: None,
        fetched_at_ms: 1L,
      },
    ]),
    calls: 0,
  }
  @devkit.quota_registry_register("quick-pick-a", source)
  let router = RouterModelPort(slots=[
    quick_pick_slot("alpha-1", "quick-pick-a"),
    quick_pick_slot("alpha-2", "quick-pick-a"),
    quick_pick_slot("beta-1", "quick-pick-b"),
  ])
  let outcome = router.invoke("model", quick_pick_args())
  @devkit.quota_registry_unregister("quick-pick-a")
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      assert_eq(feedback, "Quick-pick model slots")
      assert_true(ui_hint is Some(@posoco.UiHint::RefreshModelList))
      guard structured is Some(Json::Array(entries)) else {
        fail("expected structured slot catalog")
      }
      assert_eq(entries.length(), 3)
      match quick_pick_entry(structured, "alpha-1") {
        Some(fields) =>
          match fields.get("quota_readings") {
            Some(Json::Array(readings)) => {
              assert_eq(readings.length(), 2)
              guard readings[0] is Json::Object(first) else {
                fail("expected reading object")
              }
              match first.get("window") {
                Some(Json::String("5h")) => ()
                _ => fail("expected the 5h window")
              }
              match first.get("used_percent") {
                Some(Json::Number(value, ..)) => assert_eq(value, 25.0)
                _ => fail("expected used_percent 25.0")
              }
              guard readings[1] is Json::Object(second) else {
                fail("expected reading object")
              }
              match second.get("window") {
                Some(Json::String("weekly")) => ()
                _ => fail("expected the weekly window")
              }
              match second.get("used_percent") {
                Some(Json::Number(value, ..)) => assert_eq(value, 60.0)
                _ => fail("expected used_percent 60.0")
              }
            }
            _ => fail("expected quota_readings on the sourced provider entry")
          }
        None => fail("expected the alpha-1 catalog entry")
      }
      match quick_pick_entry(structured, "alpha-2") {
        Some(fields) => assert_true(fields.get("quota_readings") is Some(_))
        None => fail("expected the alpha-2 catalog entry")
      }
      match quick_pick_entry(structured, "beta-1") {
        Some(fields) => assert_true(fields.get("quota_readings") is None)
        None => fail("expected the beta-1 catalog entry")
      }
    }
    _ => fail("expected quick-pick success")
  }
}

///|
async test "quick-pick encodes balance readings verbatim" {
  let source : &@devkit.QuotaSource = QuickPickQuotaSource::{
    result: Ok([
      @devkit.QuotaReading::{
        window: "balance",
        used_percent: None,
        amount: Some(("110.00", "CNY")),
        available: None,
        reset_at_ms: None,
        fetched_at_ms: 42L,
      },
    ]),
    calls: 0,
  }
  @devkit.quota_registry_register("quick-pick-bal", source)
  let router = RouterModelPort(slots=[
    quick_pick_slot("bal-1", "quick-pick-bal"),
  ])
  let outcome = router.invoke("model", quick_pick_args())
  @devkit.quota_registry_unregister("quick-pick-bal")
  match outcome {
    @posoco.CommandOutcome::Success(structured~, ..) =>
      match quick_pick_entry(structured, "bal-1") {
        Some(fields) =>
          match fields.get("quota_readings") {
            Some(Json::Array(readings)) => {
              assert_eq(readings.length(), 1)
              guard readings[0] is Json::Object(reading) else {
                fail("expected reading object")
              }
              match reading.get("amount") {
                Some(Json::Object(amount)) => {
                  match amount.get("value") {
                    Some(Json::String("110.00")) => ()
                    _ => fail("expected amount value 110.00")
                  }
                  match amount.get("currency") {
                    Some(Json::String("CNY")) => ()
                    _ => fail("expected amount currency CNY")
                  }
                }
                _ => fail("expected an amount object")
              }
              match reading.get("fetched_at_ms") {
                Some(Json::Number(value, ..)) => assert_eq(value, 42.0)
                _ => fail("expected fetched_at_ms as a number")
              }
            }
            _ => fail("expected quota_readings on the balance entry")
          }
        None => fail("expected the bal-1 catalog entry")
      }
    _ => fail("expected quick-pick success")
  }
}

///|
async test "quick-pick rejects an effort argument" {
  let router = RouterModelPort(slots=[quick_pick_slot("only", "quick-pick-eff")])
  let outcome = router.invoke(
    "model",
    Json::object(
      Map::from_array([
        ("slot", Json::string("quick-pick")),
        ("effort", Json::string("high")),
      ]),
    ),
  )
  match outcome {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_eq(reason, "/model quick-pick takes no effort")
    _ => fail("expected the quick-pick effort rejection")
  }
}

///|
async test "quick-pick keyword wins over a real slot id" {
  let router = RouterModelPort(slots=[
    quick_pick_slot("plain", "quick-pick-real"),
    quick_pick_slot("quick-pick", "quick-pick-other"),
  ])
  let outcome = router.invoke("model", quick_pick_args())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_eq(feedback, "Quick-pick model slots")
      assert_eq(router.active_slot_id(), "plain")
    }
    _ => fail("expected the quick-pick listing, not a slot switch")
  }
}

///|
async test "injected quota source beats the registry" {
  let registry_source : QuickPickQuotaSource = QuickPickQuotaSource::{
    result: Err("registry source down"),
    calls: 0,
  }
  @devkit.quota_registry_register(
    "quick-pick-ovr",
    registry_source as &@devkit.QuotaSource,
  )
  let override_source : &@devkit.QuotaSource = QuickPickQuotaSource::{
    result: Ok([
      @devkit.QuotaReading::{
        window: "5h",
        used_percent: Some(10.0),
        amount: None,
        available: None,
        reset_at_ms: None,
        fetched_at_ms: 1L,
      },
    ]),
    calls: 0,
  }
  let router = RouterModelPort(
    slots=[quick_pick_slot("ovr-1", "quick-pick-ovr")],
    extra_quota_sources=Map::from_array([("quick-pick-ovr", override_source)]),
  )
  let outcome = router.invoke("model", quick_pick_args())
  @devkit.quota_registry_unregister("quick-pick-ovr")
  match outcome {
    @posoco.CommandOutcome::Success(structured~, ..) => {
      match quick_pick_entry(structured, "ovr-1") {
        Some(fields) =>
          match fields.get("quota_readings") {
            Some(Json::Array(readings)) => {
              assert_eq(readings.length(), 1)
              guard readings[0] is Json::Object(reading) else {
                fail("expected reading object")
              }
              match reading.get("used_percent") {
                Some(Json::Number(value, ..)) => assert_eq(value, 10.0)
                _ => fail("expected the override's used_percent")
              }
            }
            _ => fail("expected the override's quota_readings")
          }
        None => fail("expected the ovr-1 catalog entry")
      }
      // The override answers, so the registry source is never consulted.
      assert_eq(registry_source.calls, 0)
    }
    _ => fail("expected quick-pick success")
  }
}

///|
async test "registry failure omits the provider's quota readings" {
  let failed : QuickPickQuotaSource = QuickPickQuotaSource::{
    result: Err("quota endpoint down"),
    calls: 0,
  }
  @devkit.quota_registry_register(
    "quick-pick-err",
    failed as &@devkit.QuotaSource,
  )
  let router = RouterModelPort(slots=[
    quick_pick_slot("err-1", "quick-pick-err"),
  ])
  let outcome = router.invoke("model", quick_pick_args())
  @devkit.quota_registry_unregister("quick-pick-err")
  match outcome {
    @posoco.CommandOutcome::Success(structured~, ..) =>
      match quick_pick_entry(structured, "err-1") {
        Some(fields) => assert_true(fields.get("quota_readings") is None)
        None => fail("expected the err-1 catalog entry")
      }
    _ => fail("expected quick-pick success despite the failed source")
  }
}

///|
async test "quick-pick leads the model slot choices" {
  let router = command_test_router()
  let defs = router.commands()
  match defs[0].params[0].choices {
    Some(choices) => {
      assert_eq(choices.length(), 3)
      assert_eq(choices[0], "quick-pick")
      assert_eq(choices, ["quick-pick", "first", "second"])
    }
    None => fail("expected slot choices")
  }
}

///|
async test "quick-pick refreshes the active provider's bar segments" {
  let source : &@devkit.QuotaSource = QuickPickQuotaSource::{
    result: Ok([
      @devkit.QuotaReading::{
        window: "5h",
        used_percent: Some(25.0),
        amount: None,
        available: None,
        reset_at_ms: None,
        fetched_at_ms: 1L,
      },
    ]),
    calls: 0,
  }
  @devkit.quota_registry_register("quick-pick-active", source)
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let router = RouterModelPort(
    slots=[quick_pick_slot("s1", "quick-pick-active")],
    bus=Some(bus),
  )
  let outcome = router.invoke("model", quick_pick_args())
  @devkit.quota_registry_unregister("quick-pick-active")
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  let expected = Some(
    @devkit.StatusOp::Register(
      segment="5h",
      label=None,
      priority=45,
      value=Some("75% left"),
      color=None,
    ),
  )
  let mut found = false
  for event in capture.events {
    if @devkit.decode_status_op(event) == expected {
      found = true
    }
  }
  assert_true(found)
}
