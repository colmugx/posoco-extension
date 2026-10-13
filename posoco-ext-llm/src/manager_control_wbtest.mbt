///|
/// Manager-control contract tests for the router, driven exclusively through
/// `&ModelManagerControl` trait references. Self-contained fakes: no
/// provider adapter, no network, no endpoint configuration. Unlike the
/// native-only async suites, these are pure sync control-plane tests, so
/// the file runs on every backend.

///|
struct ControlTestPort {
  reasoning_effort_values : Array[String]
}

///|
pub impl @posoco.ModelPort for ControlTestPort with fn chat(
  _self : ControlTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(
    "control test port was not expected to chat",
  )
}

///|
pub impl @posoco.ModelPort for ControlTestPort with fn compact(
  _self : ControlTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "control test port does not implement compact",
  )
}

///|
pub impl @posoco.ModelPort for ControlTestPort with fn provider_config(
  self : ControlTestPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=self.reasoning_effort_values,
  )
}

///|
pub extend ControlTestPort with @posoco.ModelPort::{
  provider_config,
  chat,
  compact,
}

///|
fn control_test_slot(
  id : String,
  provider_id : String,
  model_id : String,
  reasoning_effort_values : Array[String],
) -> ModelSlot {
  let port : &@posoco.ModelPort = ControlTestPort::{ reasoning_effort_values, }
  ModelSlot::ModelSlot(id~, label=id, provider_id~, model_id~, port~)
}

///|
/// A slot advertising efforts with a working rebuild hook, mirroring what
/// provider extensions build for `/effort`: the rebuilt slot re-advertises
/// the same levels and keeps the hook.
fn control_effort_slot(
  id : String,
  provider_id : String,
  model_id : String,
) -> ModelSlot {
  control_effort_slot_with_hook(id, provider_id, model_id, [])
}

///|
/// Same slot, but every rebuild-hook invocation is recorded so tests can
/// observe that the provider-owned hook — not the adapter — applied the
/// effort.
fn control_effort_slot_with_hook(
  id : String,
  provider_id : String,
  model_id : String,
  hook_calls : Array[String],
) -> ModelSlot {
  let rebuilt = {
    ..control_test_slot(id, provider_id, model_id, ["low", "high"]),
    thinking_efforts: ["low", "high"],
    default_effort: Some("low"),
  }
  {
    ..rebuilt,
    rebuild_on_effort: Some(effort => {
      hook_calls.push(effort)
      rebuilt
    }),
  }
}

///|
/// Bus capture for control-contract tests: records every published event.
struct ControlCapture {
  events : Array[@devkit.BusEvent]
}

///|
fn ControlCapture::ControlCapture() -> ControlCapture {
  { events: [], }
}

///|
impl @devkit.BusSubscriber for ControlCapture with fn on_bus_event(
  self : ControlCapture,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
fn control_router(
  slots~ : Array[ModelSlot],
  default_slot_id~ : String = "",
  bus~ : @devkit.EventBus? = None,
) -> &@modelmgmt.ModelManagerControl raise @posoco.CompositionError {
  RouterModelPort::RouterModelPort(slots~, default_slot_id~, bus~)
  as &@modelmgmt.ModelManagerControl
}

///|
test "manager control reports the router identity" {
  let router = control_router(slots=[
    control_test_slot("one/a", "one", "model-a", []),
  ])
  assert_eq(router.manager_id(), "posoco_ext_llm")
}

///|
test "manager control projects the ordered catalog" {
  let router = control_router(slots=[
    control_test_slot("zulu/a", "zulu", "model-a", []),
    {
      ..control_test_slot("solo-model", "custom", "gpt-x", []),
      label: "Custom Endpoint",
      thinking_efforts: ["minimal", "max"],
      context_window: Some(128000),
      capabilities: ["chat", "tools"],
      default_effort: Some("minimal"),
      display_group: Some("Self-hosted"),
    },
    control_test_slot("alpha/b", "alpha", "model-b", []),
  ])
  let models = router.list_models()
  assert_eq(models.length(), 3)
  // Composition order survives the projection.
  assert_eq(models.map(m => m.model_id), ["zulu/a", "solo-model", "alpha/b"])
  // Metadata is carried verbatim; the opaque id is never split on `/`.
  assert_eq(models[1].label, "Custom Endpoint")
  assert_eq(models[1].provider_id, "custom")
  assert_eq(models[1].context_window, Some(128000))
  assert_eq(models[1].capabilities, ["chat", "tools"])
  assert_eq(models[1].efforts, ["minimal", "max"])
  assert_eq(models[1].default_effort, Some("minimal"))
  assert_eq(models[1].display_group, Some("Self-hosted"))
  // Absent facts stay absent: no fabricated windows or efforts.
  assert_eq(models[0].context_window, None)
  assert_eq(models[0].efforts, [])
  assert_eq(models[0].default_effort, None)
  assert_eq(models[0].display_group, None)
  // Catalog snapshots are isolated from later catalog changes.
  models[0].capabilities.push("sneaky")
  assert_eq(router.list_models()[0].capabilities, [])
}

///|
test "select_model through the control trait switches, resets effort, and preserves events" {
  let bus = @devkit.EventBus()
  let capture = ControlCapture::ControlCapture()
  bus.subscribe(capture)
  let first = control_effort_slot("one/a", "one", "model-a")
  let second = control_test_slot("two/b", "two", "model-b", [])
  let router = control_router(slots=[first, second], bus=Some(bus))
  router.select_effort("high")
  assert_eq(router.active_selection().effort, Some("high"))
  capture.events.clear()
  router.select_model("two/b")
  assert_eq(router.active_selection().model_id, "two/b")
  // Switching models resets the applied effort.
  assert_eq(router.active_selection().effort, None)
  assert_false(router.active_selection().pending)
  // Model status republication, then the provider event for the new
  // provider — the same wire shape `/model` produces.
  assert_eq(capture.events.length(), 2)
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="model",
        label=None,
        priority=20,
        value=Some("model-b:default"),
        color=None,
      ),
    ),
  )
  assert_eq(capture.events[1].topic, "provider")
  match capture.events[1].data {
    Json::Object(fields) =>
      assert_eq(fields.get("provider_id"), Some(Json::string("two")))
    _ => fail("expected a provider event payload object")
  }
}

///|
test "select_model rejects unknown ids without mutating state" {
  let bus = @devkit.EventBus()
  let capture = ControlCapture::ControlCapture()
  bus.subscribe(capture)
  let first = control_test_slot("one/a", "one", "model-a", [])
  let second = control_test_slot("two/b", "two", "model-b", [])
  let router = control_router(slots=[first, second], bus=Some(bus))
  let result = Ok(router.select_model("ghost")) catch { error => Err(error) }
  match result {
    Err(@modelmgmt.ModelManagerError::UnknownModel(detail)) =>
      assert_true(detail.contains("ghost"))
    _ => fail("expected UnknownModel")
  }
  assert_eq(router.active_selection().model_id, "one/a")
  assert_eq(router.list_models().map(m => m.model_id), ["one/a", "two/b"])
  assert_eq(capture.events.length(), 0)
}

///|
test "select_effort through the control trait applies the rebuild hook" {
  let hook_calls : Array[String] = []
  let first = control_effort_slot_with_hook(
    "one/a", "one", "model-a", hook_calls,
  )
  let router = control_router(slots=[first])
  router.select_effort("high")
  assert_eq(router.active_selection().effort, Some("high"))
  // The provider-owned rebuild hook ran exactly once and the rebuilt slot
  // still advertises its levels through the catalog.
  assert_eq(hook_calls, ["high"])
  assert_eq(router.list_models()[0].efforts, ["low", "high"])
}

///|
test "select_effort rejects unsupported efforts without corrupting state" {
  let hook_calls : Array[String] = []
  let first = control_effort_slot_with_hook(
    "one/a", "one", "model-a", hook_calls,
  )
  let router = control_router(slots=[first])
  let result = Ok(router.select_effort("bogus")) catch { error => Err(error) }
  match result {
    Err(@modelmgmt.ModelManagerError::UnsupportedEffort(detail)) => {
      assert_true(detail.contains("bogus"))
      assert_true(detail.contains("one/a"))
    }
    _ => fail("expected UnsupportedEffort")
  }
  // Nothing mutated: no sticky effort, catalog entry untouched, and the
  // provider-owned hook never ran for the rejected effort.
  assert_eq(router.active_selection().effort, None)
  assert_eq(router.list_models()[0].efforts, ["low", "high"])
  assert_eq(hook_calls, [])
  router.select_effort("low")
  assert_eq(router.active_selection().effort, Some("low"))
}

///|
test "select_effort reports effort-less models as not applicable" {
  let first = control_test_slot("one/a", "one", "model-a", [])
  let router = control_router(slots=[{ ..first, thinking_efforts: ["low"], }])
  let result = Ok(router.select_effort("low")) catch { error => Err(error) }
  match result {
    Err(@modelmgmt.ModelManagerError::EffortNotApplicable(detail)) =>
      assert_true(detail.contains("one/a"))
    _ => fail("expected EffortNotApplicable")
  }
  assert_eq(router.active_selection().effort, None)
}

///|
test "a pending selection is reported as pending and resists effort selection" {
  // A persisted default whose slot is absent: only `allow_missing_default`
  // lets the router hold the selection as a visible pending state.
  let pending : &@modelmgmt.ModelManagerControl = RouterModelPort::RouterModelPort(
      slots=[control_test_slot("one/a", "one", "model-a", [])],
      default_slot_id="ghost",
      allow_missing_default=true,
    )
    as &@modelmgmt.ModelManagerControl
  let selection = pending.active_selection()
  assert_eq(selection.model_id, "ghost")
  assert_true(selection.pending)
  let result = Ok(pending.select_effort("high")) catch { error => Err(error) }
  match result {
    Err(@modelmgmt.ModelManagerError::UnknownModel(_)) => ()
    _ => fail("expected UnknownModel for an effort on a pending selection")
  }
  // Still pending, still untouched.
  assert_true(pending.active_selection().pending)
  // Selecting a present model heals the pending state.
  pending.select_model("one/a")
  assert_false(pending.active_selection().pending)
  assert_eq(pending.active_selection().model_id, "one/a")
}

///|
test "independent routers do not share the active selection" {
  let router_a = control_router(slots=[
    control_test_slot("one/a", "one", "model-a", []),
    control_test_slot("one/b", "one", "model-b", []),
  ])
  let router_b = control_router(slots=[
    control_test_slot("one/a", "one", "model-a", []),
    control_test_slot("one/b", "one", "model-b", []),
  ])
  router_a.select_model("one/b")
  assert_eq(router_a.active_selection().model_id, "one/b")
  assert_eq(router_b.active_selection().model_id, "one/a")
}
