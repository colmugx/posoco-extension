///|
/// Router tests use an injected port so they do not require a provider
/// adapter, network access, or endpoint configuration.
struct RouterTestPort {
  reasoning_effort_values : Array[String]
}

///|
pub impl @posoco.ModelPort for RouterTestPort with fn chat(
  _self : RouterTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(
    "router test port was not expected to chat",
  )
}

///|
pub impl @posoco.ModelPort for RouterTestPort with fn compact(
  _self : RouterTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "router test port does not implement compact",
  )
}

///|
pub impl @posoco.ModelPort for RouterTestPort with fn provider_config(
  self : RouterTestPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=self.reasoning_effort_values,
  )
}

///|
fn router_test_slot(
  id : String,
  provider_id : String,
  model_id : String,
  reasoning_effort_values : Array[String],
) -> ModelSlot {
  let port : &@posoco.ModelPort = RouterTestPort::{ reasoning_effort_values, }
  ModelSlot::ModelSlot(id~, label=id, provider_id~, model_id~, port~)
}

///|
/// A slot advertising reasoning efforts with a working rebuild hook, so
/// `select_effort` can be exercised without a provider adapter.
fn router_effort_slot(
  id : String,
  provider_id : String,
  model_id : String,
) -> ModelSlot {
  let base = router_test_slot(id, provider_id, model_id, ["low", "high"])
  {
    ..base,
    thinking_efforts: ["low", "high"],
    default_effort: Some("low"),
    rebuild_on_effort: Some(_ => base),
  }
}

///|
test "router rejects an empty slot list" {
  let result = Ok(RouterModelPort(slots=[])) catch { error => Err(error) }
  match result {
    Err(@posoco.CompositionError::EmptyPort(name)) =>
      assert_eq(name, "posoco_ext_llm.slots")
    _ => fail("expected empty slot composition failure")
  }
}

///|
test "router rejects duplicate slot ids" {
  let first = router_test_slot("same", "one", "model-a", [])
  let second = router_test_slot("same", "two", "model-b", [])
  let result = Ok(RouterModelPort(slots=[first, second])) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      ignore(manifest_id)
      assert_true(detail.contains("duplicate model slot id: same"))
    }
    _ => fail("expected duplicate slot composition failure")
  }
}

///|
test "router selects the configured default and switches slots" {
  let first = router_test_slot("first", "one", "model-a", [])
  let second = router_test_slot("second", "two", "model-b", [])
  let router = RouterModelPort(slots=[first, second], default_slot_id="second")
  assert_eq(router.active_slot_id(), "second")
  assert_eq(router.current_provider_id(), "two")
  assert_eq(router.current_model_id(), "model-b")
  router.switch_slot("first") catch {
    _ => fail("unexpected slot switch failure")
  }
  assert_eq(router.active_slot_id(), "first")
  assert_eq(router.list_slot_ids(), ["first", "second"])
}

///|
test "router delegates provider config to the active slot" {
  let first = router_test_slot("first", "one", "model-a", ["low", "high"])
  let second = router_test_slot("second", "two", "model-b", ["minimal"])
  let router = RouterModelPort(slots=[first, second])
  assert_eq(router.provider_config().reasoning_effort_values, ["low", "high"])
  router.switch_slot("second") catch {
    _ => fail("unexpected slot switch failure")
  }
  assert_eq(router.provider_config().reasoning_effort_values, ["minimal"])
}

///|
test "provider config rejects ambiguous legacy and tagged credentials" {
  let oauth = @oauth.Credential::Credential(
    access_token="access",
    refresh_token="refresh",
    expires_at=0,
  )
  let api = @oauth.ApiKeyCredential::ApiKeyCredential(secret="secret")
  let source = ProviderConfigSource::ProviderConfigSource(
    provider_credential=Some(@oauth.ProviderCredential::OAuth(oauth)),
    api_key_credential=Some(api),
  )
  let result = Ok(source.effective_credential("test-provider")) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      assert_eq(manifest_id, "posoco_ext_llm.credentials")
      assert_true(detail.contains("ambiguous credential"))
    }
    _ => fail("legacy/tagged credential coexistence must fail fast")
  }
}

///|
test "replace_provider_slots expands a provider in place and keeps order" {
  let outer = router_test_slot("outer", "other", "model-o", [])
  let single = router_test_slot("one/a", "one", "model-a", [])
  let router = RouterModelPort(slots=[outer, single], default_slot_id="one/a")
  let replacements = [
    router_test_slot("one/a", "one", "model-a", []),
    router_test_slot("one/b", "one", "model-b", []),
    router_test_slot("one/c", "one", "model-c", []),
  ]
  router.replace_provider_slots("one", replacements) catch {
    _ => fail("unexpected replacement failure")
  }
  assert_eq(router.list_slot_ids(), ["outer", "one/a", "one/b", "one/c"])
  // The active slot id survived the object swap, so selection is preserved.
  assert_eq(router.active_slot_id(), "one/a")
}

///|
test "replace_provider_slots falls back when the active slot disappears" {
  let first = router_effort_slot("one/a", "one", "model-a")
  let second = router_test_slot("two/z", "two", "model-z", [])
  let router = RouterModelPort(slots=[first, second])
  router.select_effort("one/a", "high") catch {
    _ => fail("unexpected effort selection failure")
  }
  let replacements = [
    router_test_slot("one/x", "one", "model-x", []),
    router_test_slot("one/y", "one", "model-y", []),
  ]
  router.replace_provider_slots("one", replacements) catch {
    _ => fail("unexpected replacement failure")
  }
  // The old active id vanished; selection falls back to the provider's first
  // replacement slot and the effort selection is cleared.
  assert_eq(router.active_slot_id(), "one/x")
  assert_eq(router.active_effort(), None)
}

///|
test "replace_provider_slots rejects invalid replacements without mutation" {
  let single = router_test_slot("one/a", "one", "model-a", [])
  let router = RouterModelPort(slots=[single])
  let empty = Ok(router.replace_provider_slots("one", [])) catch {
    error => Err(error)
  }
  match empty {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("must not be empty"))
    _ => fail("an empty replacement list must fail fast")
  }
  let wrong_provider = [router_test_slot("two/b", "two", "model-b", [])]
  let mismatch = Ok(router.replace_provider_slots("one", wrong_provider)) catch {
    error => Err(error)
  }
  match mismatch {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("provider id does not match"))
    _ => fail("a foreign-provider replacement must fail fast")
  }
  assert_eq(router.list_slot_ids(), ["one/a"])
  assert_eq(router.active_slot_id(), "one/a")
}

///|
test "replace_provider_slots appends when the provider contributed no slots" {
  let single = router_test_slot("one/a", "one", "model-a", [])
  let router = RouterModelPort(slots=[single])
  let replacements = [
    router_test_slot("three/a", "three", "model-a", []),
    router_test_slot("three/b", "three", "model-b", []),
  ]
  router.replace_provider_slots("three", replacements) catch {
    _ => fail("unexpected replacement failure")
  }
  assert_eq(router.list_slot_ids(), ["one/a", "three/a", "three/b"])
}

///|
/// Bus capture for the status-protocol tests: records every published
/// event so assertions can decode the wire ops.
priv struct StatusCapture {
  events : Array[@devkit.BusEvent]
}

///|
fn StatusCapture::StatusCapture() -> StatusCapture {
  { events: [], }
}

///|
impl @devkit.BusSubscriber for StatusCapture with fn on_bus_event(
  self : StatusCapture,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
fn router_test_usage(
  input~ : Int?,
  output~ : Int?,
  cached~ : Int?,
) -> @posoco.Usage {
  {
    input_tokens: input,
    output_tokens: output,
    total_tokens: None,
    cached_input_tokens: cached,
    uncached_input_tokens: None,
  }
}

///|
fn router_test_message() -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("done")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
test "model response publishes model tok and cache segments" {
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let router = RouterModelPort(
    slots=[router_effort_slot("slot-a", "one", "slot-a")],
    bus=Some(bus),
  )
  router.select_effort("slot-a", "high") catch {
    _ => fail("unexpected effort selection failure")
  }
  router.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=router_test_message(),
      usage=Some(
        router_test_usage(input=Some(1200), output=Some(80), cached=Some(600)),
      ),
    ),
  )
  assert_eq(capture.events.length(), 3)
  assert_eq(capture.events[0].source, "posoco_ext_llm")
  assert_eq(capture.events[0].topic, "status")
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="tok",
        label=None,
        priority=30,
        value=Some("1200↑ 80↓"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(
      @devkit.StatusOp::Register(
        segment="cache",
        label=None,
        priority=40,
        value=Some("50%"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[2]),
    Some(
      @devkit.StatusOp::Register(
        segment="model",
        label=None,
        priority=20,
        value=Some("slot-a:high"),
        color=None,
      ),
    ),
  )
}

///|
test "model effort falls back to slot default then to default" {
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let with_default = RouterModelPort(
    slots=[router_effort_slot("slot-a", "one", "slot-a")],
    bus=Some(bus),
  )
  with_default.publish_model_status()
  let without_default = RouterModelPort(
    slots=[router_test_slot("model-b", "two", "model-b", [])],
    bus=Some(bus),
  )
  without_default.publish_model_status()
  assert_eq(capture.events.length(), 2)
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="model",
        label=None,
        priority=20,
        value=Some("slot-a:low"),
        color=None,
      ),
    ),
  )
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
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
}

///|
test "on_compose registers the model segment as initial state" {
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let router = RouterModelPort(
    slots=[router_effort_slot("slot-a", "one", "slot-a")],
    bus=Some(bus),
  )
  let ui = @posoco.NoopUiPort()
  router.on_compose(
    @posoco.tk_view(
      requires=[],
      model=router as &@posoco.ModelPort,
      ui=ui as &@posoco.UiPort,
    ),
  )
  assert_eq(capture.events.length(), 2)
  assert_eq(capture.events[0].source, "posoco_ext_llm")
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="model",
        label=None,
        priority=20,
        value=Some("slot-a:low"),
        color=None,
      ),
    ),
  )
  assert_eq(capture.events[1].topic, "provider")
  assert_eq(capture.events[1].source, "posoco_ext_llm")
}

///|
test "tok accumulates across rounds and TurnStarted resets it" {
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let router = RouterModelPort(
    slots=[router_effort_slot("slot-a", "one", "slot-a")],
    bus=Some(bus),
  )
  router.on_event(@posoco.TurnEvent::TurnStarted)
  router.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=router_test_message(),
      usage=Some(
        router_test_usage(input=Some(1200), output=Some(80), cached=Some(600)),
      ),
    ),
  )
  router.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=router_test_message(),
      usage=Some(
        router_test_usage(input=Some(300), output=Some(40), cached=None),
      ),
    ),
  )
  router.on_event(@posoco.TurnEvent::TurnStarted)
  assert_eq(capture.events.length(), 8)
  let tok_value = fn(event : @devkit.BusEvent) -> String? {
    match @devkit.decode_status_op(event) {
      Some(@devkit.StatusOp::Register(segment="tok", value~, ..)) => value
      _ => None
    }
  }
  assert_eq(tok_value(capture.events[0]), Some("0↑ 0↓"))
  assert_eq(tok_value(capture.events[1]), Some("1200↑ 80↓"))
  assert_eq(tok_value(capture.events[4]), Some("1500↑ 120↓"))
  assert_eq(tok_value(capture.events[7]), Some("0↑ 0↓"))
}

///|
test "missing cached or absent usage unregisters the cache segment" {
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let router = RouterModelPort(
    slots=[router_effort_slot("slot-a", "one", "slot-a")],
    bus=Some(bus),
  )
  // No cache segment exists before the first response.
  assert_eq(capture.events.length(), 0)
  router.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=router_test_message(),
      usage=Some(
        router_test_usage(input=Some(100), output=Some(10), cached=None),
      ),
    ),
  )
  assert_eq(capture.events.length(), 3)
  assert_eq(
    @devkit.decode_status_op(capture.events[1]),
    Some(@devkit.StatusOp::Unregister(segment="cache")),
  )
  router.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=router_test_message(),
      usage=None,
    ),
  )
  assert_eq(capture.events.length(), 6)
  assert_eq(
    @devkit.decode_status_op(capture.events[4]),
    Some(@devkit.StatusOp::Unregister(segment="cache")),
  )
}

///|
test "switch_slot republishes the model segment" {
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let first = router_test_slot("first", "one", "model-a", [])
  let second = router_test_slot("second", "two", "model-b", [])
  let router = RouterModelPort(slots=[first, second], bus=Some(bus))
  router.switch_slot("second") catch {
    _ => fail("unexpected slot switch failure")
  }
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
      match fields.get("provider_id") {
        Some(Json::String("two")) => ()
        _ => fail("expected provider_id of the newly active slot")
      }
    _ => fail("expected a provider event payload object")
  }
}

///|
test "switch_slot publishes a provider event for status consumers" {
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let first = router_test_slot("first", "one", "model-a", [])
  let second = router_test_slot("second", "two", "model-b", [])
  let router = RouterModelPort(slots=[first, second], bus=Some(bus))
  router.switch_slot("second") catch {
    _ => fail("unexpected slot switch failure")
  }
  let provider_events : Array[@devkit.BusEvent] = []
  for event in capture.events {
    if event.topic == "provider" {
      provider_events.push(event)
    }
  }
  assert_eq(provider_events.length(), 1)
  assert_eq(provider_events[0].source, "posoco_ext_llm")
  match provider_events[0].data {
    Json::Object(fields) =>
      match fields.get("provider_id") {
        Some(Json::String("two")) => ()
        _ => fail("expected the new slot's provider id")
      }
    _ => fail("expected a provider event payload object")
  }
  // Without a bus the publication is a silent no-op: the same switch
  // succeeds and mutates without publishing anything.
  let quiet_first = router_test_slot("first", "one", "model-a", [])
  let quiet_second = router_test_slot("second", "two", "model-b", [])
  let quiet = RouterModelPort(slots=[quiet_first, quiet_second])
  quiet.switch_slot("second") catch {
    _ => fail("unexpected slot switch failure")
  }
  assert_eq(quiet.active_slot_id(), "second")
}

///|
test "router without a bus keeps observing and mutating silently" {
  let router = RouterModelPort(slots=[
    router_effort_slot("slot-a", "one", "slot-a"),
  ])
  router.on_event(@posoco.TurnEvent::TurnStarted)
  router.on_event(
    @posoco.TurnEvent::ModelResponseReceived(
      message=router_test_message(),
      usage=Some(
        router_test_usage(input=Some(1200), output=Some(80), cached=Some(600)),
      ),
    ),
  )
  router.select_effort("slot-a", "low") catch {
    _ => fail("unexpected effort selection failure")
  }
  assert_eq(router.active_effort(), Some("low"))
  assert_eq(router.tokens_in, 1200)
  assert_eq(router.tokens_out, 80)
}

///|
/// ModelPort fake that answers chat successfully, so quota-refresh tests can
/// drive the router's chat path without a provider adapter.
struct RouterChatTestPort {}

///|
pub impl @posoco.ModelPort for RouterChatTestPort with fn chat(
  _self : RouterChatTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  @posoco.tk_stop_response("done")
}

///|
pub impl @posoco.ModelPort for RouterChatTestPort with fn compact(
  _self : RouterChatTestPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "router chat test port does not implement compact",
  )
}

///|
pub impl @posoco.ModelPort for RouterChatTestPort with fn provider_config(
  _self : RouterChatTestPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
/// Scripted quota source for router tests: plays one fixed result on every
/// read and counts the calls so tests can pin pull counts.
struct RouterQuotaSource {
  result : Result[Array[@devkit.QuotaReading], String]
  mut calls : Int
}

///|
pub impl @devkit.QuotaSource for RouterQuotaSource with fn read(
  self : RouterQuotaSource,
) -> Result[Array[@devkit.QuotaReading], String] {
  self.calls = self.calls + 1
  self.result
}

///|
fn router_quota_slot(id : String, provider_id : String) -> ModelSlot {
  let port : &@posoco.ModelPort = RouterChatTestPort::{ }
  ModelSlot::ModelSlot(id~, label=id, provider_id~, model_id="model-x", port~)
}

///|
fn router_quota_scope() -> @posoco.InvocationScope {
  @posoco.InvocationScope::{
    session_id: @posoco.SessionId::unchecked("router-quota-test"),
    run_id: @posoco.RunId::unchecked("run-1"),
    effect_id: None,
    pressure: None,
  }
}

///|
fn router_quota_options() -> @posoco.ChatOptions {
  @posoco.ChatOptions::{ temperature: None, max_output_tokens: None, }
}

///|
fn router_test_balance_reading() -> @devkit.QuotaReading {
  {
    window: "balance",
    used_percent: None,
    amount: Some(("5.09", "CNY")),
    available: None,
    reset_at_ms: None,
    fetched_at_ms: 1L,
  }
}

///|
/// Drive one chat through the router's ModelPort trait view.
async fn router_quota_chat(
  router : RouterModelPort,
) -> Result[Unit, @posoco.ModelError] {
  let result = Ok(
    (router as &@posoco.ModelPort).chat(
      router_quota_scope(),
      [],
      [],
      router_quota_options(),
      @posoco.StreamMode::NoStream,
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
fn router_decoded_status_ops(
  events : Array[@devkit.BusEvent],
) -> Array[@devkit.StatusOp] {
  let ops : Array[@devkit.StatusOp] = []
  for event in events {
    match @devkit.decode_status_op(event) {
      Some(op) => ops.push(op)
      None => ()
    }
  }
  ops
}

///|
async test "chat refreshes quota segments after the response" {
  let source : &@devkit.QuotaSource = RouterQuotaSource::{
    result: Ok([router_test_balance_reading()]),
    calls: 0,
  }
  @devkit.quota_registry_register("router-quota-provider", source)
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let router = RouterModelPort(
    slots=[router_quota_slot("with-source", "router-quota-provider")],
    bus=Some(bus),
  )
  let outcome = router_quota_chat(router)
  @devkit.quota_registry_unregister("router-quota-provider")
  guard outcome is Ok(_) else { fail("router chat must succeed") }
  assert_eq(
    @devkit.decode_status_op(capture.events[0]),
    Some(
      @devkit.StatusOp::Register(
        segment="balance",
        label=None,
        priority=45,
        value=Some("5.09 CNY"),
        color=None,
      ),
    ),
  )
}

///|
async test "switch clears quota segments" {
  let source : &@devkit.QuotaSource = RouterQuotaSource::{
    result: Ok([router_test_balance_reading()]),
    calls: 0,
  }
  @devkit.quota_registry_register("router-quota-provider", source)
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let router = RouterModelPort(
    slots=[
      router_quota_slot("with-source", "router-quota-provider"),
      router_quota_slot("bare", "router-quota-bare"),
    ],
    bus=Some(bus),
  )
  router.refresh_quota_now()
  assert_true(
    router_decoded_status_ops(capture.events).contains(
      @devkit.StatusOp::Register(
        segment="balance",
        label=None,
        priority=45,
        value=Some("5.09 CNY"),
        color=None,
      ),
    ),
  )
  router.switch_slot("bare") catch {
    _ => fail("unexpected slot switch failure")
  }
  @devkit.quota_registry_unregister("router-quota-provider")
  assert_eq(
    @devkit.decode_status_op(capture.events[capture.events.length() - 1]),
    Some(@devkit.StatusOp::Unregister(segment="balance")),
  )
}

///|
async test "refresh throttles within the interval" {
  let source : RouterQuotaSource = RouterQuotaSource::{
    result: Ok([router_test_balance_reading()]),
    calls: 0,
  }
  @devkit.quota_registry_register(
    "router-quota-provider",
    source as &@devkit.QuotaSource,
  )
  let router = RouterModelPort(slots=[
    router_quota_slot("with-source", "router-quota-provider"),
  ])
  let first = router_quota_chat(router)
  let second = router_quota_chat(router)
  @devkit.quota_registry_unregister("router-quota-provider")
  guard first is Ok(_) else { fail("first chat must succeed") }
  guard second is Ok(_) else { fail("second chat must succeed") }
  // The first chat pulled; the second was throttled within the interval.
  assert_eq(source.calls, 1)
}

///|
async test "failed read backs off" {
  let source : RouterQuotaSource = RouterQuotaSource::{
    result: Err("quota endpoint down"),
    calls: 0,
  }
  @devkit.quota_registry_register(
    "router-quota-provider",
    source as &@devkit.QuotaSource,
  )
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let router = RouterModelPort(
    slots=[router_quota_slot("with-source", "router-quota-provider")],
    bus=Some(bus),
  )
  let first = router_quota_chat(router)
  let second = router_quota_chat(router)
  @devkit.quota_registry_unregister("router-quota-provider")
  guard first is Ok(_) else {
    fail("first chat must succeed despite the quota failure")
  }
  guard second is Ok(_) else {
    fail("second chat must succeed despite the quota failure")
  }
  // The failed pull backs off, so the second chat never re-read and no
  // quota segment was ever registered.
  assert_eq(source.calls, 1)
  assert_eq(router_decoded_status_ops(capture.events).length(), 0)
}

///|
async test "status invoke failure backs off without clearing old segments" {
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let router = RouterModelPort(
    slots=[router_quota_slot("with-source", "router-quota-provider")],
    bus=Some(bus),
  )
  // Warm the bar straight from the cache (no pull), so the state matches a
  // successful refresh while `quota_fetched_at` stays stale — the follow-up
  // chat below is then genuinely gated by the failure backoff, not by the
  // 30-minute throttle.
  router.quota_readings = [router_test_balance_reading()]
  router.publish_quota_segments()
  let failed_source : RouterQuotaSource = RouterQuotaSource::{
    result: Err("quota endpoint down"),
    calls: 0,
  }
  @devkit.quota_registry_register(
    "router-quota-provider",
    failed_source as &@devkit.QuotaSource,
  )
  let outcome = router.invoke("status", Json::null())
  let chat_outcome = router_quota_chat(router)
  @devkit.quota_registry_unregister("router-quota-provider")
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  guard chat_outcome is Ok(_) else {
    fail("chat must succeed despite the quota failure")
  }
  // The failed /status neither retracted the warm balance segment nor
  // published anything new: the bus still carries exactly that one register.
  assert_eq(router_decoded_status_ops(capture.events), [
    @devkit.StatusOp::Register(
      segment="balance",
      label=None,
      priority=45,
      value=Some("5.09 CNY"),
      color=None,
    ),
  ])
  // The chat after the failed /status stayed inside the 5-minute backoff:
  // the failing source was read only by /status itself.
  assert_eq(failed_source.calls, 1)
}
