///|
priv struct MetadataTestTransport {
  mut calls : Int32
  mut payload : Json
  mut broken : Bool
}

///|
impl ModelMetadataTransport for MetadataTestTransport with fn fetch(
  self : MetadataTestTransport,
) -> Json {
  self.calls += 1
  @async.sleep(1)
  if self.broken {
    fail("offline")
  }
  self.payload
}

///|
priv struct MetadataTestStore {
  mut value : Json?
  mut writes : Int32
  mut broken : Bool
}

///|
impl ModelMetadataStore for MetadataTestStore with fn read(
  self : MetadataTestStore,
) -> Json? {
  self.value
}

///|
impl ModelMetadataStore for MetadataTestStore with fn write(
  self : MetadataTestStore,
  value : Json,
) -> Unit {
  if self.broken {
    fail("disk full")
  }
  self.value = Some(value)
  self.writes += 1
}

///|
fn metadata_fixture() -> Json {
  {
    "deepseek": {
      "models": {
        "deepseek-flash": { "limit": { "context": 1000000 } },
        "fraction": { "limit": { "context": 1.5 } },
        "zero": { "limit": { "context": 0 } },
        "overflow": { "limit": { "context": 2147483648.0 } },
      },
    },
    "zai": { "models": { "glm-5.3": { "limit": { "context": 200000 } } } },
    "zai-coding-plan": {
      "models": { "glm-5.3": { "limit": { "context": 1000000 } } },
    },
  }
}

///|
test "context windows reject invalid and derived discovery records" {
  for
    value in [
      Json::number(0.0),
      Json::number(-1.0),
      Json::number(1.5),
      Json::number(2147483648.0),
      Json::string("100000"),
    ] {
    assert_eq(@provider.context_window_integer(Some(value)), None)
  }
  assert_eq(
    @provider.context_window_integer(Some(Json::number(2147483647.0))),
    Some(2147483647),
  )
  let records : Json = [
    { "model_id": "known", "context_window": 120000 },
    {
      "model_id": "fallback",
      "context_window": 500000,
      "context_window_source": "fallback",
    },
    {
      "model_id": "configured",
      "context_window": 90000,
      "context_window_source": "configured",
    },
    {
      "model_id": "derived",
      "context_window": 300000,
      "context_window_source": "models_dev",
    },
  ]
  assert_eq(
    @provider.cached_provider_context_window(Some(records), "known"),
    Some(120000),
  )
  for id in ["fallback", "configured", "derived", "missing"] {
    assert_eq(@provider.cached_provider_context_window(Some(records), id), None)
  }
}

///|
async test "models.dev caches requested providers and resolves exact serving ids" {
  let transport = MetadataTestTransport::{
    calls: 0,
    payload: metadata_fixture(),
    broken: false,
  }
  let store = MetadataTestStore::{ value: None, writes: 0, broken: false, }
  let metadata = ModelMetadata(transport~, store=Some(store))
  metadata.refresh(["deepseek", "zai-coding-plan"], now=1000L)
  assert_eq(transport.calls, 1)
  assert_eq(store.writes, 1)
  assert_eq(
    metadata.lookup("deepseek", "deepseek-flash", now=1000L).tokens,
    1000000,
  )
  assert_eq(
    metadata.lookup("zai-coding-plan", "glm-5.3", now=1000L).tokens,
    1000000,
  )
  assert_eq(metadata.lookup("zai", "glm-5.3", now=1000L).source, "fallback")
  for id in ["fraction", "zero", "overflow", "missing"] {
    assert_eq(metadata.lookup("deepseek", id, now=1000L).tokens, 500000)
  }
  metadata.refresh(["deepseek"], now=2000L)
  assert_eq(transport.calls, 1)
  let restarted = ModelMetadata(transport~, store=Some(store))
  restarted.refresh(["deepseek"], now=3000L)
  assert_eq(transport.calls, 1)
  assert_eq(
    restarted.lookup("deepseek", "deepseek-flash", now=3000L).source,
    "models_dev",
  )
}

///|
async test "models.dev failed refresh retains stale cache and backs off" {
  let transport = MetadataTestTransport::{
    calls: 0,
    payload: metadata_fixture(),
    broken: false,
  }
  let warnings : Array[String] = []
  let metadata = ModelMetadata(transport~, warn=fn(message) {
    warnings.push(message)
  })
  metadata.refresh(["deepseek"], now=1000L)
  transport.broken = true
  metadata.refresh(["deepseek"], now=86_401_000L)
  assert_true(
    metadata.lookup("deepseek", "deepseek-flash", now=86_401_000L).stale,
  )
  assert_eq(
    metadata.lookup("deepseek", "deepseek-flash", now=86_401_000L).tokens,
    1000000,
  )
  metadata.refresh(["deepseek"], now=86_402_000L)
  assert_eq(transport.calls, 2)
  assert_eq(warnings.length(), 1)
  transport.broken = false
  metadata.refresh(["deepseek"], now=86_462_000L)
  assert_eq(transport.calls, 3)
  assert_false(
    metadata.lookup("deepseek", "deepseek-flash", now=86_462_000L).stale,
  )
}

///|
async test "models.dev malformed cache and write failures remain visible" {
  let transport = MetadataTestTransport::{
    calls: 0,
    payload: metadata_fixture(),
    broken: false,
  }
  let store = MetadataTestStore::{
    value: Some({ "version": 99 }),
    writes: 0,
    broken: true,
  }
  let warnings : Array[String] = []
  let metadata = ModelMetadata(transport~, store=Some(store), warn=fn(message) {
    warnings.push(message)
  })
  metadata.refresh(["deepseek"], now=1000L)
  assert_eq(warnings.length(), 2)
  assert_eq(
    metadata.lookup("deepseek", "deepseek-flash", now=1000L).tokens,
    1000000,
  )
  assert_eq(store.writes, 0)
  store.broken = false
  transport.payload = Json::null()
  metadata.refresh(["deepseek"], now=86_401_000L)
  assert_eq(warnings.length(), 3)
  assert_eq(
    metadata.lookup("deepseek", "deepseek-flash", now=86_401_000L).tokens,
    1000000,
  )
  transport.payload = metadata_fixture()
  metadata.refresh(["deepseek"], now=86_462_000L)
  assert_eq(store.writes, 1)
}

///|
async test "models.dev concurrent refresh shares one fetch" {
  let transport = MetadataTestTransport::{
    calls: 0,
    payload: metadata_fixture(),
    broken: false,
  }
  let metadata = ModelMetadata(transport~)
  @async.with_task_group(group => {
    group.spawn_bg(() => metadata.refresh(["deepseek"], now=1000L))
    group.spawn_bg(() => metadata.refresh(["deepseek"], now=1000L))
  })
  assert_eq(transport.calls, 1)
}

///|
async test "router effective window reaches provider_config and status" {
  let transport = MetadataTestTransport::{
    calls: 0,
    payload: metadata_fixture(),
    broken: false,
  }
  let metadata = ModelMetadata(transport~)
  metadata.refresh(["deepseek"], now=@async.now())
  let slot = ModelSlot(
    id="deepseek/deepseek-flash",
    label="DeepSeek",
    provider_id="deepseek",
    model_id="deepseek-flash",
    port=RouterTestPort::{ reasoning_effort_values: [], },
  )
  let router = RouterModelPort(slots=[slot], model_metadata=Some(metadata))
  assert_eq(router.provider_config().context_window, Some(1000000))
  assert_eq(router.context_window_reading(slot).source, "models_dev")
  let (_, status) = router.status_report()
  guard status is Json::Object(fields) else { fail("status must be object") }
  assert_eq(fields.get("context_window"), Some(Json::number(1000000.0)))
  assert_eq(
    fields.get("context_window_source"),
    Some(Json::string("models_dev")),
  )
  let fallback = RouterModelPort(slots=[slot])
  assert_eq(fallback.provider_config().context_window, Some(500000))
  assert_eq(fallback.context_window_reading(slot).source, "fallback")
  let configured = {
    ..slot,
    context_window: Some(65000),
    context_window_source: "configured",
  }
  let overridden = RouterModelPort(
    slots=[configured],
    model_metadata=Some(metadata),
  )
  assert_eq(overridden.provider_config().context_window, Some(65000))
  assert_eq(overridden.context_window_reading(configured).source, "configured")
}

///|
priv struct BlockingMetadataTransport {
  mut calls : Int32
}

///|
impl ModelMetadataTransport for BlockingMetadataTransport with fn fetch(
  self : BlockingMetadataTransport,
) -> Json {
  self.calls += 1
  if self.calls == 1 {
    @async.sleep(10000)
  }
  metadata_fixture()
}

///|
async test "models.dev cancellation releases refresh gate and allows retry" {
  let transport = BlockingMetadataTransport::{ calls: 0, }
  let metadata = ModelMetadata(transport~)
  try
    @async.with_timeout(10, () => metadata.refresh(["deepseek"], now=1000L))
  catch {
    @async.TimeoutError => ()
    err => raise err
  } noraise {
    _ => fail("expected timeout")
  }
  assert_eq(
    metadata.lookup("deepseek", "deepseek-flash", now=1000L).source,
    "fallback",
  )
  metadata.refresh(["deepseek"], now=1001L)
  assert_eq(transport.calls, 2)
  assert_eq(
    metadata.lookup("deepseek", "deepseek-flash", now=1001L).tokens,
    1000000,
  )
}

///|
priv struct WindowPolicyTestPort {
  occupancy : Int32
  rounds : Int32
  mut calls : Int32
  windows : Array[Int32?]
}

///|
impl @posoco.ModelPort for WindowPolicyTestPort with fn chat(
  self : WindowPolicyTestPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.calls += 1
  let tool_calls : Array[@posoco.ToolCall] = if self.calls <= self.rounds {
    [
      {
        call_id: @posoco.CallId::unchecked("call_" + self.calls.to_string()),
        name: @posoco.ToolName::unchecked("unknown_test_tool"),
        arguments: {},
      },
    ]
  } else {
    []
  }
  {
    processed_messages: messages.to_owned(),
    completion: @posoco.Completion(
      content=[@posoco.Content::Text("done")],
      tool_calls~,
      reasoning=None,
      finish_reason=if tool_calls.is_empty() {
        @posoco.FinishReason::Stop
      } else {
        @posoco.FinishReason::ToolCalls
      },
      usage=Some({
        input_tokens: Some(self.occupancy),
        output_tokens: Some(0),
        total_tokens: Some(self.occupancy),
        cached_input_tokens: None,
        uncached_input_tokens: None,
      }),
    ),
  }
}

///|
impl @posoco.ModelPort for WindowPolicyTestPort with fn compact(
  self : WindowPolicyTestPort,
  scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  if !(trigger is @posoco.CompactTrigger::Auto) {
    raise @posoco.ModelError::RequestBuild("expected automatic compaction")
  }
  self.windows.push(scope.pressure.bind(pressure => pressure.window_tokens))
  {
    compacted_messages: [
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("summary")]),
    ],
    mode: @posoco.CompactMode::Replace,
  }
}

///|
impl @posoco.ModelPort for WindowPolicyTestPort with fn provider_config(
  _self : WindowPolicyTestPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
priv struct WindowPolicyTestExtension {
  router : RouterModelPort
}

///|
impl @posoco.Extension for WindowPolicyTestExtension with fn extension_id(
  _self : WindowPolicyTestExtension,
) -> String {
  "window_policy_test"
}

///|
impl @posoco.Extension for WindowPolicyTestExtension with fn manifest(
  self : WindowPolicyTestExtension,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="window_policy_test", models=[self.router])
}

///|
async fn exercise_window_policy(
  metadata : ModelMetadata?,
  occupancy : Int32,
  rounds : Int32,
) -> Array[Int32?] {
  let port = WindowPolicyTestPort::{ occupancy, rounds, calls: 0, windows: [], }
  let router = RouterModelPort(
    slots=[
      ModelSlot(
        id="deepseek/deepseek-flash",
        label="DeepSeek",
        provider_id="deepseek",
        model_id="deepseek-flash",
        port~,
      ),
    ],
    model_metadata=metadata,
  )
  let agent = @posoco.Agent(
    exts=[WindowPolicyTestExtension::{ router, }],
    config=@posoco.agent_config(
      max_tool_rounds=Some(10),
      compact_threshold=Some(0.8),
    ),
  )
  ignore(
    agent.run_turn(
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("hello")]),
      "window_policy_session",
    ),
  )
  assert_eq(port.calls, rounds + 1)
  port.windows
}

///|
async test "Agent auto compact uses models.dev and fallback rather than cumulative usage" {
  let transport = MetadataTestTransport::{
    calls: 0,
    payload: metadata_fixture(),
    broken: false,
  }
  let metadata = ModelMetadata(transport~)
  metadata.refresh(["deepseek"], now=@async.now())
  assert_eq(exercise_window_policy(Some(metadata), 810000, 1), [Some(1000000)])
  assert_eq(exercise_window_policy(None, 410000, 1), [Some(500000)])
  assert_eq(exercise_window_policy(Some(metadata), 500000, 2), [])
  assert_eq(exercise_window_policy(None, 250000, 2), [])
}

///|
async test "metadata warnings only describe the active fallback model once" {
  let transport = MetadataTestTransport::{
    calls: 0,
    payload: metadata_fixture(),
    broken: false,
  }
  let warnings : Array[String] = []
  let metadata = ModelMetadata(transport~, warn=fn(message) {
    warnings.push(message)
  })
  let slots = ["deepseek-flash", "unknown-a", "unknown-b", "unknown-c"].map(model => {
    ModelSlot(
      id="deepseek/" + model,
      label=model,
      provider_id="deepseek",
      model_id=model,
      port=RouterTestPort::{ reasoning_effort_values: [], },
    )
  })
  let router = RouterModelPort(slots~, model_metadata=Some(metadata))
  router.refresh_model_metadata()
  assert_eq(warnings.length(), 0)
  router.switch_slot("deepseek/unknown-a")
  router.refresh_model_metadata()
  router.refresh_model_metadata()
  assert_eq(warnings.length(), 1)
  assert_true(warnings[0].contains("deepseek/unknown-a"))
  assert_true(warnings[0].contains("500000"))
  assert_true(warnings[0].contains("overflow"))
  router.switch_slot("deepseek/unknown-b")
  router.refresh_model_metadata()
  assert_eq(warnings.length(), 2)
  router.switch_slot("deepseek/unknown-a")
  router.refresh_model_metadata()
  assert_eq(warnings.length(), 2)
}

///|
async test "empty metadata provider key opts out of models.dev refresh" {
  let transport = MetadataTestTransport::{
    calls: 0,
    payload: metadata_fixture(),
    broken: false,
  }
  let metadata = ModelMetadata(transport~)
  let slot = ModelSlot(
    id="relay/ghost-model",
    label="relay",
    provider_id="relay",
    model_id="ghost-model",
    port=RouterTestPort::{ reasoning_effort_values: [], },
    metadata_provider_id=Some(""),
  )
  let router = RouterModelPort(slots=[slot], model_metadata=Some(metadata))
  router.refresh_model_metadata()
  assert_eq(transport.calls, 0)
  assert_eq(router.context_window_reading(router.list_slots()[0]), {
    tokens: 500_000,
    source: "fallback",
    stale: false,
  })
}

///|
async test "partial metadata responses back off and repeated diagnostics do not spam" {
  let transport = MetadataTestTransport::{
    calls: 0,
    payload: metadata_fixture(),
    broken: false,
  }
  let warnings : Array[String] = []
  let metadata = ModelMetadata(transport~, warn=fn(message) {
    warnings.push(message)
  })
  metadata.refresh(["deepseek", "missing-a", "missing-b"], now=1000L)
  assert_eq(transport.calls, 1)
  assert_eq(warnings.length(), 1)
  assert_true(warnings[0].contains("missing-a, missing-b"))
  metadata.refresh(["deepseek", "missing-a", "missing-b"], now=2000L)
  assert_eq(transport.calls, 1)
  metadata.refresh(["deepseek", "missing-a", "missing-b"], now=62000L)
  assert_eq(transport.calls, 2)
  assert_eq(warnings.length(), 1)
  transport.broken = true
  metadata.refresh(["missing-a"], now=123000L)
  assert_eq(warnings.length(), 2)
  metadata.refresh(["missing-a"], now=184000L)
  assert_eq(transport.calls, 4)
  assert_eq(warnings.length(), 2)
  assert_true(warnings[1].contains("offline"))
  transport.broken = false
  metadata.refresh(["zai"], now=245000L)
  assert_eq(metadata.lookup("zai", "glm-5.3", now=245000L).tokens, 200000)
}

///|
/// Legacy public helper names must remain callable from ext-llm after the
/// canonical decoding implementation moves to posoco-kit-provider.
test "legacy context-window helper entry points remain available" {
  let json = Some(Json::number(128000.0))
  assert_eq(
    context_window_integer(json),
    @provider.context_window_integer(json),
  )
  let records = Some(
    Json::array([
      Json::object({
        "model_id": Json::string("m"),
        "context_window": Json::number(128000.0),
        "context_window_source": Json::string("provider"),
      }),
    ]),
  )
  assert_eq(cached_provider_context_window(records, "m"), Some(128000))
  assert_eq(
    cached_provider_context_window(records, "m", metadata_provider_id="p"),
    @provider.cached_provider_context_window(
      records,
      "m",
      metadata_provider_id="p",
    ),
  )
}
