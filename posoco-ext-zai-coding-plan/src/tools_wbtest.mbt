///|
/// Lifecycle of the tools companion, offline: a scripted plane and a recording
/// contribution handle stand in for the network and the kernel.

///|
/// Scripted plane: `connected` of the declared groups answered, each with one
/// tool, and every close is recorded so a leak is visible.
struct FakeConnection {
  connected : Int32
  defs : Array[@posoco.ToolDef]
  closes : Array[Int32]
}

///|
fn fake_connection(
  groups : Array[ZaiToolGroup],
  connected : Int32,
) -> FakeConnection {
  let defs : Array[@posoco.ToolDef] = []
  for index, group in groups {
    if index >= connected {
      break
    }
    defs.push(
      @posoco.ToolDef(
        name=@posoco.ToolName::unchecked(
          zai_mcp_namespaced_tool(group.group, "run"),
        ),
        description=group.title,
        input_schema=Json::object({ "type": Json::string("object") }),
        owner=@posoco.OwnerId::unchecked(zai_coding_plan_tools_owner()),
        policy=@posoco.ExecutionPolicy::Parallel,
        provenance=None,
      ),
    )
  }
  { connected, defs, closes: [], }
}

///|
impl ZaiMcpConnection for FakeConnection with fn tools(self : FakeConnection) -> Array[
  @posoco.ToolDef,
] {
  self.defs.copy()
}

///|
impl ZaiMcpConnection for FakeConnection with fn connected_groups(
  self : FakeConnection,
) -> Int32 {
  self.connected
}

///|
impl ZaiMcpConnection for FakeConnection with fn failures(
  _self : FakeConnection,
) -> Array[String] {
  []
}

///|
impl ZaiMcpConnection for FakeConnection with fn call(
  self : FakeConnection,
  tool : String,
  arguments : Json,
) -> Result[String, String] noraise {
  let _ = (self, tool, arguments)
  Ok("scripted")
}

///|
impl ZaiMcpConnection for FakeConnection with fn close(self : FakeConnection) -> Unit noraise {
  self.closes.push(self.connected)
}

///|
/// Recording contribution handle: counts replaces/withdrawals and keeps the
/// last published tool names.
struct FakeContributions {
  replaces : Array[Int32]
  withdraws : Array[String]
  mut published : Array[String]
  retired : Array[Int32]
}

///|
fn fake_contributions() -> FakeContributions {
  { replaces: [], withdraws: [], published: [], retired: [], }
}

///|
fn fake_handle(record : FakeContributions) -> @posoco.ToolContributions {
  @posoco.ToolContributions::from_callbacks(
    owner=zai_coding_plan_tools_owner(),
    replace=fn(
      provider : &@posoco.ToolProvider,
      retirer : @posoco.ToolRetire?,
    ) -> Result[@posoco.ToolContributionCommit, @posoco.ToolContributionError] noraise {
      record.replaces.push(1)
      record.published = provider
        .list_tools()
        .map(fn(def) { def.name.to_string() })
      match retirer {
        Some(_) => record.retired.push(1)
        None => ()
      }
      Ok({
        owner: zai_coding_plan_tools_owner(),
        revision: 1,
        state: @posoco.ToolContributionState::Active,
      })
    },
    withdraw=fn(
      mode : @posoco.ToolWithdrawMode,
    ) -> Result[@posoco.ToolContributionCommit, @posoco.ToolContributionError] noraise {
      record.withdraws.push(mode.to_string())
      Ok({
        owner: zai_coding_plan_tools_owner(),
        revision: 2,
        state: @posoco.ToolContributionState::Withdrawn,
      })
    },
    revision=fn() { Some(1) },
    state=fn() { @posoco.ToolContributionState::Active },
  )
}

///|
fn test_config() -> @zai.ZaiConfig {
  @zai.ZaiConfig::for_model(
    "sk-test",
    "glm-5.3-flash",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/anthropic",
  )
}

///|
/// Status recorder for the `mcp` segment: subscribes to the session event
/// system and keeps the announced values (`<hidden>` for an unregister), so a
/// switch is directly observable.
struct SegmentRecorder {
  values : Array[String]
}

///|
fn SegmentRecorder::bind(
  self : SegmentRecorder,
  system : @posoco.EventSystem,
) -> Unit {
  let _subscription = system
    .subscribe(fn(envelope) {
      if @kit_events.publisher_id(envelope) !=
        Some(zai_coding_plan_tools_owner()) {
        return
      }
      match @kit_events.status_changed_of(envelope) {
        Some(@kit_events.Register(segment="mcp", value~, ..)) =>
          match value {
            Some(value) => self.values.push(value)
            None => self.values.push("<none>")
          }
        Some(@kit_events.Unregister(segment="mcp")) =>
          self.values.push("<hidden>")
        _ => ()
      }
    })
    .unwrap()
}

///|
test "slot ids split into provider and model" {
  inspect(
    zai_slot_provider("zai-coding-plan/glm-5.3-flash"),
    content="zai-coding-plan",
  )
  inspect(
    zai_slot_model("zai-coding-plan/glm-5.3-flash"),
    content="glm-5.3-flash",
  )
  inspect(zai_slot_provider("builder"), content="builder")
  inspect(zai_slot_model("builder"), content="builder")
}

///|
test "ownership follows the slot's provider prefix" {
  inspect(
    zai_coding_plan_owns_slot("zai-coding-plan/glm-5.3-flash"),
    content="true",
  )
  inspect(zai_coding_plan_owns_slot("deepseek/deepseek-flash"), content="false")
  inspect(zai_coding_plan_owns_slot(""), content="false")
}

///|
/// Build a companion with a scripted plane and a recording handle, run
/// `on_start`, and hand the pieces back for assertions.
async fn start_case(
  group : @async.TaskGroup[Unit],
  connected~ : Int32,
) -> (ZaiCodingPlanTools, FakeContributions, SegmentRecorder) {
  let system = @posoco.EventSystem()
  let recorder : SegmentRecorder = { values: [], }
  recorder.bind(system)
  let record = fake_contributions()
  let tools = ZaiCodingPlanTools(
    config=test_config(),
    group~,
    initial_slot_id="zai-coding-plan/glm-5.3-flash",
    open_plane=fn(
      _api_key,
      groups,
    ) -> Result[&ZaiMcpConnection, String] noraise {
      Ok(fake_connection(groups, connected) as &ZaiMcpConnection)
    },
  )
  tools.events = Some(
    system.publisher(owner=zai_coding_plan_tools_owner()).unwrap(),
  )
  tools.contributions = Some(fake_handle(record))
  tools.on_start()
  (tools, record, recorder)
}

///|
async test "resuming on this provider announces the declared group" {
  @async.with_task_group(async fn(group) {
    let (tools, record, recorder) = start_case(group, connected=3)
    inspect(record.replaces.length(), content="1")
    inspect(
      record.published.join(","),
      content="web_search_prime__run,web_reader__run,zread__run",
    )
    inspect(tools.state.to_repr(), content="Ready(total=3)")
    // Reported as it happens: connecting, then the settled count.
    inspect(
      recorder.values.join(" | "),
      content="0/3 Official MCP | 3/3 Official MCP",
    )
  })
}

///|
async test "a partial connect is announced but never reads as success" {
  @async.with_task_group(async fn(group) {
    let (tools, record, recorder) = start_case(group, connected=2)
    inspect(record.replaces.length(), content="1")
    inspect(tools.state.to_repr(), content="Degraded(connected=2, total=3)")
    inspect(
      recorder.values.join(" | "),
      content="0/3 Official MCP | 2/3 Official MCP",
    )
  })
}

///|
async test "switching away withdraws softly and hides the segment" {
  @async.with_task_group(async fn(group) {
    let (tools, record, recorder) = start_case(group, connected=3)
    tools.deactivate()
    inspect(record.withdraws.join(","), content="Soft")
    inspect(tools.state.to_repr(), content="Inactive")
    inspect(
      recorder.values.join(" | "),
      content="0/3 Official MCP | 3/3 Official MCP | <hidden>",
    )
  })
}

///|
async test "a resume on another provider starts idle" {
  @async.with_task_group(async fn(group) {
    let system = @posoco.EventSystem()
    let record = fake_contributions()
    let tools = ZaiCodingPlanTools(
      config=test_config(),
      group~,
      initial_slot_id="deepseek/deepseek-flash",
      open_plane=fn(
        _api_key,
        _groups,
      ) -> Result[&ZaiMcpConnection, String] noraise {
        Ok(fake_connection([], 0) as &ZaiMcpConnection)
      },
    )
    tools.events = Some(
      system.publisher(owner=zai_coding_plan_tools_owner()).unwrap(),
    )
    tools.contributions = Some(fake_handle(record))
    tools.on_start()
    inspect(record.replaces.length(), content="0")
    inspect(tools.state.to_repr(), content="Inactive")
  })
}

///|
async test "an unusable host declares nothing and opens nothing" {
  @async.with_task_group(async fn(group) {
    let opened : Array[Int32] = [0]
    let tools = ZaiCodingPlanTools(
      config=@zai.ZaiConfig::for_model(
        "sk-test",
        "glm-5.3-flash",
        base_url="",
        endpoint_prefix="/api/anthropic",
      ),
      group~,
      initial_slot_id="",
      open_plane=fn(
        _api_key,
        groups,
      ) -> Result[&ZaiMcpConnection, String] noraise {
        opened[0] = opened[0] + 1
        Ok(fake_connection(groups, 0) as &ZaiMcpConnection)
      },
    )
    tools.activate("glm-5.3-flash")
    inspect(opened[0], content="0")
    inspect(tools.state.to_repr(), content="Inactive")
  })
}

///|
/// Recording log sink: keeps the records a failed activation reports.
struct FakeLog {
  records : Array[@posoco.LogRecord]
}

///|
impl @posoco.LogPort for FakeLog with fn write(
  self : FakeLog,
  record : @posoco.LogRecord,
  durability : @posoco.LogDurability,
) -> Unit {
  let _ = durability
  self.records.push(record)
}

///|
impl @posoco.LogPort for FakeLog with fn flush(_self : FakeLog) -> Unit {
  ()
}

///|
async test "a plane that cannot open reports 0/3, publishes nothing, and says why" {
  @async.with_task_group(async fn(group) {
    let system = @posoco.EventSystem()
    let recorder : SegmentRecorder = { values: [], }
    recorder.bind(system)
    let record = fake_contributions()
    let sink : FakeLog = { records: [], }
    let tools = ZaiCodingPlanTools(
      config=test_config(),
      group~,
      initial_slot_id="zai-coding-plan/glm-5.3-flash",
      open_plane=fn(
        _api_key,
        _groups,
      ) -> Result[&ZaiMcpConnection, String] noraise {
        Err("zai-coding-plan connect failed")
      },
    )
    tools.events = Some(
      system.publisher(owner=zai_coding_plan_tools_owner()).unwrap(),
    )
    tools.contributions = Some(fake_handle(record))
    tools.log = Some(sink as &@posoco.LogPort)
    tools.on_start()
    inspect(tools.state.to_repr(), content="Degraded(connected=0, total=3)")
    // Nothing was announced: a failed plane must not publish an empty group.
    inspect(record.replaces.length(), content="0")
    inspect(
      recorder.values.join(" | "),
      content="0/3 Official MCP | 0/3 Official MCP",
    )
    inspect(sink.records.length(), content="1")
    inspect(sink.records[0].event, content="mcp.activate.failed")
    inspect(
      sink.records[0].message.unwrap(),
      content="zai-coding-plan connect failed",
    )
  })
}

///|
/// One router `model_selection` envelope, exactly as the ext-llm router
/// publishes it: `Extension("posoco_ext_llm")` namespace, typed payload.
fn selection_envelope(slot_id : String) -> @posoco.EventEnvelope {
  @posoco.EventEnvelope::EventEnvelope(
    namespace_=@posoco.EventNamespace::Extension("posoco_ext_llm"),
    event=@kit_events.ModelSelection({ slot_id, effort: None, }),
  )
}

///|
test "the selection feed reads only the router's ModelSelection" {
  assert_eq(
    zai_selection_slot(selection_envelope("zai-coding-plan/glm-5.3-flash")),
    Some("zai-coding-plan/glm-5.3-flash"),
  )
  // The publisher filter survives the migration: another owner's selection
  // (a second provider router) never steers this companion.
  assert_eq(
    zai_selection_slot(
      @posoco.EventEnvelope::EventEnvelope(
        namespace_=@posoco.EventNamespace::Extension("posoco_ext_openai"),
        event=@kit_events.ModelSelection({
          slot_id: "zai-coding-plan/glm-5.3-flash",
          effort: None,
        }),
      ),
    ),
    None,
  )
  // Core notifications are not a selection either.
  assert_eq(
    zai_selection_slot(
      @posoco.EventEnvelope::EventEnvelope(
        namespace_=@posoco.EventNamespace::Posoco,
        event=@kit_events.ModelSelection({
          slot_id: "zai-coding-plan/glm-5.3-flash",
          effort: None,
        }),
      ),
    ),
    None,
  )
  // An empty slot is the router's "nothing selected".
  assert_eq(zai_selection_slot(selection_envelope("")), None)
}

///|
/// Wait until `ready()` holds, so a background switch is observed without
/// trusting scheduler timing.
async fn await_switch(ready : () -> Bool) -> Unit {
  while !ready() {
    @async.sleep(1)
  }
}

///|
async test "a router selection drives the tool plane through the typed feed" {
  @async.with_task_group(async fn(group) {
    let (tools, record, recorder) = start_case(group, connected=3)
    inspect(
      recorder.values.join(" | "),
      content="0/3 Official MCP | 3/3 Official MCP",
    )
    // Leaving this provider withdraws softly, exactly as an untyped topic
    // switch used to.
    tools.on_selection(selection_envelope("deepseek/deepseek-flash"))
    @async.with_timeout(2000, () => await_switch(() => tools.state is Inactive))
    inspect(record.withdraws.join(","), content="Soft")
    inspect(
      recorder.values.join(" | "),
      content="0/3 Official MCP | 3/3 Official MCP | <hidden>",
    )
    // ... and coming back re-declares the group.
    tools.on_selection(selection_envelope("zai-coding-plan/glm-5.3-flash"))
    @async.with_timeout(2000, () => await_switch(() => tools.state is Ready(_)))
    inspect(tools.state.to_repr(), content="Ready(total=3)")
    inspect(record.replaces.length(), content="2")
  })
}
