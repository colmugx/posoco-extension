///|
/// `/status` command tests. Self-contained on purpose: this file carries its
/// own ModelPort fake because the router_wbtest.mbt helpers are native-gated
/// and an ungated wbtest cannot reference them on other targets.

///|
struct StatusTestPort {}

///|
pub impl @posoco.ModelPort for StatusTestPort with fn chat(
  _self : StatusTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(
    "status test port was not expected to chat",
  )
}

///|
pub impl @posoco.ModelPort for StatusTestPort with fn compact(
  _self : StatusTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "status test port does not implement compact",
  )
}

///|
pub impl @posoco.ModelPort for StatusTestPort with fn provider_config(
  _self : StatusTestPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(reasoning_effort_values=[])
}

///|
fn status_test_slot() -> ModelSlot {
  let port : &@posoco.ModelPort = StatusTestPort::{ }
  ModelSlot::ModelSlot(
    id="slot-a",
    label="Slot A",
    provider_id="provider-a",
    model_id="model-a",
    port~,
    thinking_efforts=["low", "high"],
    context_window=Some(200000),
  )
}

///|
fn status_test_router(
  bus? : @devkit.EventBus? = None,
) -> RouterModelPort raise @posoco.CompositionError {
  RouterModelPort(slots=[status_test_slot()], bus~)
}

///|
async test "status command reports active model facts" {
  let router = status_test_router()
  let outcome = router.invoke("status", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      assert_true(feedback.contains("provider: provider-a"))
      assert_true(feedback.contains("model: model-a"))
      assert_true(feedback.contains("effort: default"))
      assert_true(feedback.contains("context window: 200000 tokens"))
      assert_true(feedback.contains("reasoning efforts: low,high"))
      assert_true(ui_hint is Some(@posoco.UiHint::None))
      match structured {
        Some(Json::Object(fields)) => {
          match fields.get("model") {
            Some(Json::String("model-a")) => ()
            _ => fail("expected model in structured status")
          }
          match fields.get("context_window") {
            Some(Json::Number(_)) => ()
            _ => fail("expected numeric context_window in structured status")
          }
          match fields.get("reasoning_efforts") {
            Some(Json::Array(values)) => assert_eq(values.length(), 2)
            _ => fail("expected reasoning_efforts array in structured status")
          }
        }
        _ => fail("expected structured status object")
      }
    }
    _ => fail("expected successful status report")
  }
}

///|
async test "status command surfaces cached quota windows" {
  let bus = @devkit.EventBus()
  let router = status_test_router(bus=Some(bus))
  @devkit.publish_status_register(
    bus,
    source="posoco_ext_openai",
    segment="5h",
    priority=45,
    value="62%",
  )
  @devkit.publish_status_register(
    bus,
    source="posoco_ext_openai",
    segment="weekly",
    priority=46,
    value="13%",
  )
  let outcome = router.invoke("status", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_true(feedback.contains("5h: 62%"))
      assert_true(feedback.contains("weekly: 13%"))
    }
    _ => fail("expected successful status report")
  }
  @devkit.publish_status_unregister(
    bus,
    source="posoco_ext_openai",
    segment="5h",
  )
  let after = router.invoke("status", Json::null())
  match after {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_false(feedback.contains("5h:"))
      assert_true(feedback.contains("weekly: 13%"))
    }
    _ => fail("expected successful status report")
  }
}

///|
async test "status command without quota readings states absence" {
  let router = status_test_router()
  let outcome = router.invoke("status", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("quota: no readings yet"))
      match structured {
        Some(Json::Object(fields)) =>
          match fields.get("quota") {
            Some(Json::Null) => ()
            _ => fail("expected null quota without readings")
          }
        _ => fail("expected structured status object")
      }
    }
    _ => fail("expected successful status report")
  }
}

///|
async test "status command renders registry readings for windows and balance" {
  let router = status_test_router()
  let readings : Array[@devkit.QuotaReading] = [
    {
      window: "5h",
      used_percent: Some(34.0),
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 1L,
    },
    {
      window: "balance",
      used_percent: None,
      amount: Some(("110.00", "CNY")),
      available: Some(true),
      reset_at_ms: None,
      fetched_at_ms: 1L,
    },
  ]
  let (feedback, structured) = router.status_report(readings~)
  assert_true(feedback.contains("5h: 66% left"))
  assert_true(feedback.contains("balance: 110.00 CNY"))
  match structured {
    Json::Object(fields) =>
      match fields.get("quota") {
        Some(Json::Object(quota)) => {
          match quota.get("5h") {
            Some(Json::String("66% left")) => ()
            _ => fail("expected structured 5h window")
          }
          match quota.get("balance") {
            Some(Json::String("110.00 CNY")) => ()
            _ => fail("expected structured balance reading")
          }
        }
        _ => fail("expected structured quota object")
      }
    _ => fail("expected structured status object")
  }
}

///|
async test "status command renders registry readings as percent left" {
  let router = status_test_router()
  let readings : Array[@devkit.QuotaReading] = [
    {
      window: "5h",
      used_percent: Some(34.0),
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 1L,
    },
    {
      window: "weekly",
      used_percent: Some(13.0),
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 1L,
    },
  ]
  let (feedback, structured) = router.status_report(readings~)
  assert_true(feedback.contains("5h: 66% left"))
  assert_true(feedback.contains("weekly: 87% left"))
  match structured {
    Json::Object(fields) =>
      match fields.get("quota") {
        Some(Json::Object(quota)) => {
          match quota.get("5h") {
            Some(Json::String("66% left")) => ()
            _ => fail("expected structured 5h window as percent left")
          }
          match quota.get("weekly") {
            Some(Json::String("87% left")) => ()
            _ => fail("expected structured weekly window as percent left")
          }
        }
        _ => fail("expected structured quota object")
      }
    _ => fail("expected structured status object")
  }
}

///|
async test "status command keeps bus windows over registry duplicates" {
  let bus = @devkit.EventBus()
  let router = status_test_router(bus=Some(bus))
  @devkit.publish_status_register(
    bus,
    source="posoco_ext_openai",
    segment="5h",
    priority=45,
    value="62%",
  )
  let readings : Array[@devkit.QuotaReading] = [
    {
      window: "5h",
      used_percent: Some(34.0),
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 1L,
    },
    {
      window: "weekly",
      used_percent: Some(13.0),
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 1L,
    },
  ]
  let (feedback, structured) = router.status_report(readings~)
  // The bus-published value wins; the registry reading only fills the
  // window the bus has not published.
  assert_true(feedback.contains("5h: 62%"))
  assert_false(feedback.contains("66%"))
  assert_true(feedback.contains("weekly: 87% left"))
  match structured {
    Json::Object(fields) =>
      match fields.get("quota") {
        Some(Json::Object(quota)) =>
          match quota.get("5h") {
            Some(Json::String("62%")) => ()
            _ => fail("expected the bus value in structured quota")
          }
        _ => fail("expected structured quota object")
      }
    _ => fail("expected structured status object")
  }
}

///|
async test "status command with only an unavailable balance drops absence" {
  let router = status_test_router()
  let readings : Array[@devkit.QuotaReading] = [
    {
      window: "balance",
      used_percent: None,
      amount: None,
      available: Some(false),
      reset_at_ms: None,
      fetched_at_ms: 2L,
    },
  ]
  let (feedback, structured) = router.status_report(readings~)
  assert_false(feedback.contains("no readings yet"))
  assert_true(feedback.contains("balance: unavailable"))
  match structured {
    Json::Object(fields) =>
      match fields.get("quota") {
        Some(Json::Object(quota)) =>
          match quota.get("balance") {
            Some(Json::String("unavailable")) => ()
            _ => fail("expected structured unavailable balance")
          }
        _ => fail("expected structured quota object")
      }
    _ => fail("expected structured status object")
  }
}

///|
async test "status command skips balance readings that state nothing" {
  let router = status_test_router()
  let readings : Array[@devkit.QuotaReading] = [
    {
      window: "balance",
      used_percent: None,
      amount: None,
      available: None,
      reset_at_ms: None,
      fetched_at_ms: 3L,
    },
  ]
  let (feedback, structured) = router.status_report(readings~)
  assert_true(feedback.contains("quota: no readings yet"))
  assert_false(feedback.contains("balance:"))
  match structured {
    Json::Object(fields) =>
      match fields.get("quota") {
        Some(Json::Null) => ()
        _ => fail("expected null quota when readings state nothing")
      }
    _ => fail("expected structured status object")
  }
}

///|
/// Scripted quota source for the status invoke test.
struct StatusQuotaSource {
  result : Result[Array[@devkit.QuotaReading], String]
  mut calls : Int
}

///|
pub impl @devkit.QuotaSource for StatusQuotaSource with fn read(
  self : StatusQuotaSource,
) -> Result[Array[@devkit.QuotaReading], String] {
  self.calls = self.calls + 1
  self.result
}

///|
/// Bus capture for the status invoke test.
struct StatusBusCapture {
  events : Array[@devkit.BusEvent]
}

///|
impl @devkit.BusSubscriber for StatusBusCapture with fn on_bus_event(
  self : StatusBusCapture,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
async test "status invoke warms the statusbar segments" {
  let source : &@devkit.QuotaSource = StatusQuotaSource::{
    result: Ok([
      {
        window: "balance",
        used_percent: None,
        amount: Some(("110.00", "CNY")),
        available: Some(true),
        reset_at_ms: None,
        fetched_at_ms: 1L,
      },
    ]),
    calls: 0,
  }
  @devkit.quota_registry_register("provider-a", source)
  let bus = @devkit.EventBus()
  let capture = StatusBusCapture::{ events: [], }
  bus.subscribe(capture)
  let router = status_test_router(bus=Some(bus))
  let outcome = router.invoke("status", Json::null())
  @devkit.quota_registry_unregister("provider-a")
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="balance",
        label=None,
        priority=45,
        value=Some("110.00 CNY"),
        color=None,
      ),
    ),
  )
}
