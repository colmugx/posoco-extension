// ---------------------------------------------------------------------------
// Test fakes + helpers for the `agent` tool (whitebox).
//
// The fake composer builds a real child Agent from testkit fakes
// (ScriptedModel + RecordingSessionPort) and records every ChildSpec it
// receives.
// ---------------------------------------------------------------------------

///|
priv struct FakeComposer {
  response_text : String
  /// When set, the child uses this model instead of a ScriptedModel
  /// (used by the timeout test).
  slow_model : &@posoco.ModelPort?
  child_recorder : @tk.RecordingObserver
  store : @tk.RecordingSessionPort
  specs : Array[ChildSpec]
  fail_with : String?
}

///|
fn FakeComposer::FakeComposer(
  response_text~ : String,
  slow_model~ : &@posoco.ModelPort? = None,
  fail_with~ : String? = None,
) -> FakeComposer {
  {
    response_text,
    slow_model,
    child_recorder: @tk.RecordingObserver::RecordingObserver(),
    store: @tk.RecordingSessionPort::RecordingSessionPort(),
    specs: [],
    fail_with,
  }
}

///|
impl ChildComposer for FakeComposer with fn compose(
  self : FakeComposer,
  spec : ChildSpec,
) -> @posoco.Agent raise ComposerError {
  match self.fail_with {
    Some(reason) => raise ComposerError::Failed(reason)
    None => ()
  }
  self.specs.push(spec)
  let observers : Array[&@posoco.Observer] = []
  for observer in spec.observers {
    observers.push(observer)
  }
  observers.push(self.child_recorder as &@posoco.Observer)
  let model : &@posoco.ModelPort = match self.slow_model {
    Some(slow) => slow
    None =>
      @tk.ScriptedModel([Respond(@tk.tk_stop_response(self.response_text))])
      as &@posoco.ModelPort
  }
  @posoco.Agent(
    exts=[
      @tk.tk_ext(id="model", model=Some(model)),
      @tk.tk_ext(
        id="io",
        sessions=[self.store as &@posoco.SessionPort],
        observers~,
      ),
    ],
    config=@tk.tk_config(),
    events=@posoco.EventSystem(),
  ) catch {
    error => raise ComposerError::Failed("child compose failed: \{error}")
  }
}

///|
/// ModelPort fake that never answers in time: sleeps far longer than any
/// test spawn timeout, then returns a stop response nobody will read.
priv struct SlowModel {
  delay_ms : Int32
}

///|
fn SlowModel::SlowModel(delay_ms~ : Int32) -> SlowModel {
  { delay_ms, }
}

///|
impl @posoco.ModelPort for SlowModel with fn chat(
  self : SlowModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  @async.sleep(self.delay_ms)
  @tk.tk_stop_response("too late")
}

///|
impl @posoco.ModelPort for SlowModel with fn compact(
  _self : SlowModel,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "SlowModel does not implement compact",
  )
}

///|
impl @posoco.ModelPort for SlowModel with fn provider_config(_self : SlowModel) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
fn test_tools(
  composer~ : &ChildComposer,
  config~ : @kit.SubagentConfig = @kit.SubagentConfig::defaults(),
  parent_selection~ : (() -> (String, String?))? = None,
  observers~ : Array[(@kit.SubagentEvent) -> Unit] = [],
  catalog~ : @kind.KindCatalog = @kind.KindCatalog::builtin(),
  auto_wakeup~ : Bool = false,
  question~ : QuestionBroker? = None,
) -> SubagentTools {
  SubagentTools::SubagentTools(
    catalog~,
    config~,
    composer~,
    parent_slot="parent/slot",
    parent_effort=None,
    parent_selection~,
    observers~,
    auto_wakeup~,
    question~,
  )
}

///|
/// Catalog with a builtin-like coder, a model+effort-bound kind, and an
/// unbound kind on the inherited default face.
fn catalog_with_bound_kind() -> @kind.KindCatalog {
  let coder : @kind.KindSpec = {
    name: "coder",
    description: "Full-face coding agent",
    tools: Some(["read", "write", "edit", "glob", "grep", "bash"]),
    model: None,
    effort: None,
    skills: None,
    mode: @permission.PermissionMode::WorkspaceWrite,
    body: "Coder body {{instructions}}",
  }
  let porter : @kind.KindSpec = {
    name: "porter",
    description: "Bound reconnaissance kind",
    tools: Some(["read"]),
    model: Some("kimi/k2"),
    effort: Some("high"),
    skills: None,
    mode: @permission.PermissionMode::ReadOnly,
    body: "Bound body {{instructions}}",
  }
  let loose : @kind.KindSpec = {
    name: "loose",
    description: "Unbound kind on the inherited default face",
    tools: None,
    model: None,
    effort: None,
    skills: None,
    mode: @permission.PermissionMode::WorkspaceWrite,
    body: "Loose body {{instructions}}",
  }
  @kind.KindCatalog::with_entries([coder, porter, loose]) catch {
    _ => abort("unreachable")
  }
}

///|
/// Config routing unbound kinds to a distinct default slot (and optionally a
/// default effort).
fn config_with_default(
  model~ : String,
  effort~ : String? = None,
) -> @kit.SubagentConfig {
  {
    default_model: Some(model),
    default_effort: effort,
    limits: @kit.SubagentConfig::defaults().limits,
  }
}

///|
test "list_tools_description_lists_kind_catalog" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    catalog=catalog_with_bound_kind(),
  )
  let def = @posoco.ToolProvider::list_tools(tools)[0]
  assert_true(def.description.contains("Available kinds (pass via kind):"))
  assert_true(def.description.contains("- coder: "))
  assert_true(def.description.contains(" [default]"))
  assert_true(
    def.description.contains(
      "- porter: Bound reconnaissance kind (model: kimi/k2, effort: high)",
    ),
  )
  assert_true(
    def.description.contains(
      "Omit model/effort to use the kind's binding, then the configured default, then your current selection.",
    ),
  )
  assert_false(def.description.contains("Available models"))
}

///|
test "list_tools_description_advertises_configured_default_model" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    config=config_with_default(model="mtplx/local-fast", effort=Some("low")),
  )
  let def = @posoco.ToolProvider::list_tools(tools)[0]
  assert_true(
    def.description.contains(
      "Default subagent model: mtplx/local-fast (effort low)",
    ),
  )
}

///|
fn config_with_spawn_budget(budget : Int32) -> @kit.SubagentConfig {
  let base = @kit.SubagentConfig::defaults()
  { ..base, limits: { ..base.limits, spawn_budget: budget, }, }
}

///|
fn config_with_global_concurrency(limit : Int32) -> @kit.SubagentConfig {
  let base = @kit.SubagentConfig::defaults()
  {
    ..base,
    limits: { ..base.limits, global_concurrency: limit, spawn_budget: 8, },
  }
}

///|
fn agent_call(arguments : Json) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("agent-test"),
    name: @posoco.ToolName::unchecked("subagent"),
    arguments,
  }
}

///|
/// Adapt a legacy ToolCall to the 0.21 ToolCallContext shape.
fn test_ctx(call : @posoco.ToolCall) -> @posoco.ToolCallContext {
  @posoco.ToolCallContext(
    effect_id=@kernel.EffectId::{ value: 1, },
    call_id=call.call_id,
    name=call.name,
    arguments=call.arguments,
    register_cancel=fn(_ : &@posoco.ToolCancellable) { () },
  )
}

///|
fn args_object(pairs : Array[(String, Json)]) -> Json {
  Json::object(Map::from_array(pairs))
}

///|
fn store_contains_user_text(
  store : @tk.RecordingSessionPort,
  session_id : String,
  needle : String,
) -> Bool {
  if !store.store.contains(session_id) {
    return false
  }
  let saved = store.store[session_id]
  for message in saved.messages {
    match message {
      @posoco.Message::UserMessage(content~) =>
        for block in content {
          match block {
            @posoco.Content::Text(text) =>
              if text.contains(needle) {
                return true
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  false
}

// ---------------------------------------------------------------------------
// Sync surface tests
// ---------------------------------------------------------------------------

///|
/// Content of a tool outcome, success or tool-reported error ("" otherwise).
fn outcome_content(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => content
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => content
    _ => ""
  }
}

///|
/// String value of one `structured` field on a tool outcome; "" when the
/// outcome carries no structured payload or no such string field.
fn outcome_field(outcome : @posoco.ToolOutcome, key : String) -> String {
  match outcome {
    @posoco.ToolOutcome::Success(structured~, ..) =>
      match structured {
        Some(data) => json_string_field(data, key)
        None => ""
      }
    _ => ""
  }
}

///|
/// `stop_subagent` call for the tool-context adapter.
fn stop_call(child_session : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("stop-test"),
    name: @posoco.ToolName::unchecked("stop_subagent"),
    arguments: args_object([("child_session", Json::string(child_session))]),
  }
}

///|
fn any_input_contains(inputs : Array[String], needle : String) -> Bool {
  for input in inputs {
    if input.contains(needle) {
      return true
    }
  }
  false
}

///|
/// `background` is the default: omitted → background, explicit `true` →
/// background, explicit `false` → the blocking foreground run. The type
/// check is unchanged (a non-boolean is still an argument error).
test "parse_spawn_args_defaults_to_background_and_honors_explicit_false" {
  let omitted = parse_spawn_args(args_object([("task", Json::string("t"))]))
  assert_true(omitted.background)
  let explicit_true = parse_spawn_args(
    args_object([
      ("task", Json::string("t")),
      ("background", Json::boolean(true)),
    ]),
  )
  assert_true(explicit_true.background)
  let explicit_false = parse_spawn_args(
    args_object([
      ("task", Json::string("t")),
      ("background", Json::boolean(false)),
    ]),
  )
  assert_false(explicit_false.background)
  try {
    ignore(
      parse_spawn_args(
        args_object([
          ("task", Json::string("t")),
          ("background", Json::string("yes")),
        ]),
      ),
    )
    fail("expected a background type error")
  } catch {
    SpawnArgError::Invalid(message) =>
      assert_true(message.contains("'background' must be a boolean"))
    _ => fail("expected a SpawnArgError")
  }
}

///|
async test "inheritance_reads_live_parent_selection_at_each_spawn" {
  let composer = FakeComposer::FakeComposer(response_text="ok")
  let active_slot = Ref("parent/a")
  let active_effort : Ref[String?] = Ref(None)
  let tools = test_tools(
    composer=composer as &ChildComposer,
    parent_selection=Some(fn() { (active_slot.val, active_effort.val) }),
  )

  let first = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("first")),
          ("background", Json::boolean(false)),
        ]),
      ),
    ),
  )
  assert_true(first is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs.length(), 1)
  assert_eq(composer.specs[0].slot, "parent/a")
  assert_true(composer.specs[0].effort is None)

  active_slot.val = "parent/b"
  active_effort.val = Some("high")

  let second = @posoco.ToolProvider::execute(
    tools,
    test_ctx(
      agent_call(
        args_object([
          ("task", Json::string("second")),
          ("background", Json::boolean(false)),
        ]),
      ),
    ),
  )
  assert_true(second is @posoco.ToolOutcome::Success(_))
  assert_eq(composer.specs.length(), 2)
  assert_eq(composer.specs[1].slot, "parent/b")
  assert_eq(composer.specs[1].effort, Some("high"))
}

///|
test "list_tools_declares_agent_schema_and_description" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let defs = @posoco.ToolProvider::list_tools(tools)
  assert_eq(defs.length(), 3)
  let def = defs[0]
  assert_eq(def.name.to_string(), "subagent")
  assert_true(def.policy is @posoco.ExecutionPolicy::Parallel)
  assert_true(def.description.contains("cannot spawn further subagents"))
  assert_true(def.description.contains("user-position slot"))
  assert_true(def.description.contains("instruction slot"))
  assert_true(def.description.contains("NEVER copy task content"))
  assert_true(def.description.contains("default 30 minutes"))
  assert_true(def.description.contains("waiting_reply"))
  assert_true(
    def.description.contains("By default the child runs in the background"),
  )
  assert_true(def.description.contains("background=false"))
  assert_true(def.description.contains("acceptance receipt"))
  assert_true(def.description.contains("follow-up turn"))
  assert_true(def.description.contains("stop_subagent"))
  match def.input_schema {
    Json::Object(fields) => {
      let required = match fields.get("required") {
        Some(Json::Array(items)) => items
        _ => fail("schema must declare a required array")
      }
      assert_eq(required.length(), 1)
      assert_eq(required[0], Json::string("task"))
      let properties = match fields.get("properties") {
        Some(Json::Object(props)) => props
        _ => fail("schema must declare properties")
      }
      assert_true(properties.contains("effort"))
      assert_true(properties.contains("timeout_ms"))
      assert_true(properties.contains("background"))
      assert_true(properties.contains("resume"))
      guard properties.get("background") is Some(Json::Object(background)) else {
        fail("background must be an object schema")
      }
      guard background.get("description") is Some(Json::String(background_desc)) else {
        fail("background must carry a description")
      }
      // Background is the default: the schema must say so, not the old opt-in.
      assert_true(background_desc.contains("default true"))
      assert_false(background_desc.contains("default false"))
    }
    _ => fail("schema must be a JSON object")
  }
  let answer_def = defs[1]
  assert_eq(answer_def.name.to_string(), "answer_question")
  assert_true(answer_def.policy is @posoco.ExecutionPolicy::Sequential)
  assert_true(answer_def.description.contains("waiting_reply receipt"))
  match answer_def.input_schema {
    Json::Object(fields) => {
      let required = match fields.get("required") {
        Some(Json::Array(items)) => items
        _ => fail("answer schema must declare a required array")
      }
      assert_eq(required.length(), 1)
      assert_eq(required[0], Json::string("question_id"))
    }
    _ => fail("answer schema must be a JSON object")
  }
  let stop_def = defs[2]
  assert_eq(stop_def.name.to_string(), "stop_subagent")
  assert_true(stop_def.policy is @posoco.ExecutionPolicy::Sequential)
  assert_true(stop_def.description.contains("requests the cancellation"))
  assert_true(stop_def.description.contains("background=false"))
  match stop_def.input_schema {
    Json::Object(fields) => {
      let required = match fields.get("required") {
        Some(Json::Array(items)) => items
        _ => fail("stop schema must declare a required array")
      }
      assert_eq(required.length(), 1)
      assert_eq(required[0], Json::string("child_session"))
      let properties = match fields.get("properties") {
        Some(Json::Object(props)) => props
        _ => fail("stop schema must declare properties")
      }
      assert_true(properties.contains("child_session"))
    }
    _ => fail("stop schema must be a JSON object")
  }
}

///|
test "manifest_declares_tool_provider_hook_observer_lifecycle_and_requires" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  assert_eq(tools.extension_id(), "posoco_ext_subagent")
  let manifest = tools.manifest()
  assert_eq(manifest.id, "posoco_ext_subagent")
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.models.length(), 0)
  assert_eq(manifest.sessions.length(), 0)
  // The before_model hook observes delivered background outcomes at the
  // delivery point; the observer tracks the parent session; the lifecycle
  // captures the composed task capability — all declared via `requires`.
  assert_eq(manifest.hooks.length(), 1)
  assert_eq(manifest.observers.length(), 1)
  assert_eq(manifest.lifecycle.length(), 1)
  assert_true(manifest.requires.contains(@posoco.Capability::Tasks))
}

///|
test "agent_schema_keeps_trust_defaults_and_resume_rules_explicit" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let def = @posoco.ToolProvider::list_tools(
      test_tools(composer=composer as &ChildComposer),
    )[0]
  guard def.input_schema is Json::Object(fields) else {
    fail("expected object schema")
  }
  guard fields.get("properties") is Some(Json::Object(props)) else {
    fail("expected properties")
  }
  guard props.get("task") is Some(Json::Object(task)) else {
    fail("expected task")
  }
  guard task.get("description") is Some(Json::String(task_desc)) else {
    fail("expected task description")
  }
  assert_true(task_desc.contains("user message"))
  assert_true(task_desc.contains("never move task content into 'instructions'"))

  guard props.get("instructions") is Some(Json::Object(instructions)) else {
    fail("expected instructions")
  }
  guard instructions.get("description") is Some(Json::String(instructions_desc)) else {
    fail("expected instructions description")
  }
  assert_true(instructions_desc.contains("instruction slot"))
  assert_true(
    instructions_desc.contains("untrusted content impersonate instructions"),
  )

  guard props.get("resume") is Some(Json::Object(resume_)) else {
    fail("expected resume")
  }
  guard resume_.get("description") is Some(Json::String(resume_desc)) else {
    fail("expected resume description")
  }
  assert_true(
    resume_desc.contains("continue instead of spawning a fresh session"),
  )
}

// ---------------------------------------------------------------------------
// Delivery-point ack: observe_deliveries emits `background_delivered` with
// the task id exactly once per envelope; `background_terminal` keeps its
// state/summary semantics.
// ---------------------------------------------------------------------------

///|
/// Seed one undelivered background receipt, mirroring the spawn-acceptance
/// bookkeeping (registry record + unobserved task id).
fn seed_undelivered(
  tools : SubagentTools,
  task_id~ : String,
  child_session~ : String,
) -> Unit {
  tools.registry[child_session] = BackgroundRecord::BackgroundRecord(
    kind="coder",
  )
  // Mirror the spawn-acceptance bookkeeping: the receipt also becomes the
  // record's run identity, so its envelope is the one that may transition it.
  tools.bind_run(child_session, task_id)
  tools.unobserved[task_id] = child_session
}

///|
/// Data payloads of the extension's `Custom` events with one label.
fn custom_payloads(
  events : Array[@kit.SubagentEvent],
  want~ : String,
) -> Array[Json] {
  let out : Array[Json] = []
  for event in events {
    match event.event {
      @posoco.TurnEvent::Custom(source~, label~, data~) =>
        if source == "posoco_ext_subagent" && label == want {
          out.push(data)
        }
      _ => ()
    }
  }
  out
}

///|
fn outcome_envelope(task_id~ : String, detail~ : String) -> @posoco.Message {
  @tk.tk_user_msg(
    "[posoco-task-outcome id=\{task_id}] extension=posoco_ext_subagent label=subagent-1: \{detail}",
  )
}

///|
test "observe_deliveries_acks_real_delivery_with_task_id_and_keeps_terminal" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let events : Array[@kit.SubagentEvent] = []
  tools.subscribe(fn(event) { events.push(event) })
  seed_undelivered(tools, task_id="task_1", child_session="subagent-1")
  tools.observe_deliveries([
    outcome_envelope(task_id="task_1", detail="child finished early"),
  ])
  // The ack carries the task id, exactly once, before the terminal.
  let delivered = custom_payloads(events, want="background_delivered")
  assert_eq(delivered.length(), 1)
  guard delivered[0] is Json::Object(fields) else {
    fail("delivered payload must be an object")
  }
  assert_eq(fields.get("task_id"), Some(Json::string("task_1")))
  assert_eq(fields.get("child_session"), Some(Json::string("subagent-1")))
  // Terminal semantics retained: authoritative state + summary.
  let terminal = custom_payloads(events, want="background_terminal")
  assert_eq(terminal.length(), 1)
  guard terminal[0] is Json::Object(terminal_fields) else {
    fail("terminal payload must be an object")
  }
  assert_eq(terminal_fields.get("state"), Some(Json::string("completed")))
  assert_eq(
    terminal_fields.get("summary"),
    Some(Json::string("child finished early")),
  )
  assert_eq(tools.background_children(), [("subagent-1", "completed")])
}

///|
test "observe_deliveries_duplicate_scans_ack_once" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let events : Array[@kit.SubagentEvent] = []
  tools.subscribe(fn(event) { events.push(event) })
  seed_undelivered(tools, task_id="task_1", child_session="subagent-1")
  let envelope = outcome_envelope(task_id="task_1", detail="done once")
  tools.observe_deliveries([envelope])
  // Re-delivery scans (replayed session, later turn) are no-ops.
  tools.observe_deliveries([envelope])
  tools.observe_deliveries([@tk.tk_user_msg("plain follow-up")])
  assert_eq(custom_payloads(events, want="background_delivered").length(), 1)
  assert_eq(custom_payloads(events, want="background_terminal").length(), 1)
  assert_eq(tools.background_children(), [("subagent-1", "completed")])
}

///|
test "observe_deliveries_acks_each_task_id_exactly_once" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let events : Array[@kit.SubagentEvent] = []
  tools.subscribe(fn(event) { events.push(event) })
  seed_undelivered(tools, task_id="task_1", child_session="subagent-1")
  seed_undelivered(tools, task_id="task_2", child_session="subagent-2")
  tools.observe_deliveries([
    outcome_envelope(task_id="task_1", detail="first done"),
    outcome_envelope(task_id="task_2", detail="failed: exploded"),
  ])
  let delivered = custom_payloads(events, want="background_delivered")
  assert_eq(delivered.length(), 2)
  let ids : Array[String] = []
  for data in delivered {
    ids.push(json_string_field(data, "task_id"))
  }
  assert_eq(ids, ["task_1", "task_2"])
  assert_eq(custom_payloads(events, want="background_terminal").length(), 2)
  assert_eq(tools.background_children(), [
    ("subagent-1", "completed"),
    ("subagent-2", "failed"),
  ])
  // A second scan of both envelopes acks nothing new.
  tools.observe_deliveries([
    outcome_envelope(task_id="task_1", detail="first done"),
    outcome_envelope(task_id="task_2", detail="failed: exploded"),
  ])
  assert_eq(delivered.length(), 2)
}

// ---------------------------------------------------------------------------
// Run identity at the delivery point: a terminal only transitions the run it
// names. `stop` + `resume` leaves the replaced run's envelope in flight, and it
// still reclaims that run's handle without touching its successor.
// ---------------------------------------------------------------------------

///|
/// Stand-in `TaskHandle` for whitebox bookkeeping tests: only the receipt
/// identity and the cancellation callback matter to the live-run registry.
fn fake_handle(cancelled : Array[String]) -> @posoco.TaskHandle {
  @posoco.TaskHandle::from_callbacks(
    receipt={
      id: "task_1",
      session_id: "parent",
      mode: @posoco.TaskMode::Background,
      label: "subagent-1",
      extension_id: "posoco_ext_subagent",
    },
    wait=async fn(_receipt) {
      @async.pause()
      abort("fake handle: wait is never called")
    },
    cancel=fn(receipt) { cancelled.push(receipt.id) },
  )
}

///|
/// Boolean value of one field in a `Custom` event's JSON payload; a missing
/// field or non-boolean value projects to `false`.
fn json_bool_field(data : Json, key : String) -> Bool {
  match data {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(Json::True) => true
        _ => false
      }
    _ => false
  }
}

///|
test "terminal_of_a_superseded_run_is_delivered_once_without_polluting" {
  let broker = QuestionBroker::QuestionBroker(answer_timeout_ms=60000L)
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(
    composer=composer as &ChildComposer,
    question=Some(broker),
  )
  let events : Array[@kit.SubagentEvent] = []
  tools.subscribe(fn(event) { events.push(event) })
  seed_undelivered(tools, task_id="task_old", child_session="subagent-1")
  tools.unobserved["task_new"] = "subagent-1"
  tools.bind_run("subagent-1", "task_new")
  let cancelled : Array[String] = []
  tools.track_live("subagent-1", "task_new", fake_handle(cancelled))
  // The resumed run parked its own question before the replaced run's
  // `cancelled` envelope arrives.
  let info = broker.register(
    "subagent-1",
    "child-call",
    @posoco.UiRequest::Input(prompt="new?", default=None),
  )
  assert_eq(tools.background_children(), [("subagent-1", "waiting_reply")])
  tools.observe_deliveries([
    outcome_envelope(task_id="task_old", detail="cancelled: replaced by resume"),
  ])
  // Delivered exactly once, as its own run's terminal ...
  let terminals = custom_payloads(events, want="background_terminal")
  assert_eq(terminals.length(), 1)
  assert_eq(json_string_field(terminals[0], "task_id"), "task_old")
  assert_eq(json_string_field(terminals[0], "state"), "cancelled")
  assert_true(json_bool_field(terminals[0], "superseded"))
  assert_eq(custom_payloads(events, want="background_delivered").length(), 1)
  // ... and the current run keeps its state, its question, and its handle.
  assert_eq(tools.background_children(), [("subagent-1", "waiting_reply")])
  assert_true(broker.lookup(info.id) is QuestionLookup::Open(_))
  assert_eq(broker.take_queued().length(), 1)
  assert_true(cancelled.is_empty())
  match tools.live.get("subagent-1") {
    Some(entry) => assert_eq(entry.task_id, "task_new")
    None => fail("the current run must keep its handle")
  }
}

///|
test "repeat_terminal_of_a_finished_run_still_reclaims_its_handle" {
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer)
  let events : Array[@kit.SubagentEvent] = []
  tools.subscribe(fn(event) { events.push(event) })
  seed_undelivered(tools, task_id="task_1", child_session="subagent-1")
  // An interactive run records its terminal in-wave (`finish`), long before
  // the delivery channel hands over the same run's envelope.
  match tools.registry.get("subagent-1") {
    Some(record) => record.state = Done("completed", "in-wave finish")
    None => fail("expected the seeded record")
  }
  let cancelled : Array[String] = []
  tools.bind_run("subagent-1", "task_1")
  tools.track_live("subagent-1", "task_1", fake_handle(cancelled))
  tools.observe_deliveries([
    outcome_envelope(task_id="task_1", detail="in-wave finish"),
  ])
  // The repeat is an idempotent no-op for the state and the authoritative
  // event, but it reclaims the finished run's handle.
  assert_eq(tools.background_children(), [("subagent-1", "completed")])
  assert_eq(custom_payloads(events, want="background_terminal").length(), 0)
  assert_eq(custom_payloads(events, want="background_delivered").length(), 1)
  assert_true(tools.live.get("subagent-1") is None)
}

// ---------------------------------------------------------------------------
// Automatic wakeup gating: observe_ready schedules one ordinary turn per
// undelivered accepted task; everything else stays lazy.
// ---------------------------------------------------------------------------

///|
priv struct WakeupRecorder {
  requests : Array[(String, String)]
}

///|
fn WakeupRecorder::WakeupRecorder() -> WakeupRecorder {
  { requests: [], }
}

///|
fn wakeup_recorder_port(recorder : WakeupRecorder) -> @posoco.WakeupPort {
  @posoco.WakeupPort::from_request(request=fn(session, tag, _note) {
    recorder.requests.push((session, tag))
    Ok({ id: "ticket-1", session, tag, enqueued_at: 0L, })
  })
}

///|
fn outcome_ready_event(
  task_id~ : String,
  session~ : String,
) -> @posoco.TurnEvent {
  @posoco.TurnEvent::Custom(
    source="posoco.tasks",
    label="background_outcome_ready",
    data=Json::object(
      Map::from_array([
        ("task_id", Json::string(task_id)),
        ("session", Json::string(session)),
      ]),
    ),
  )
}

///|
test "observe_ready_requests_one_turn_for_undelivered_accepted_tasks" {
  let recorder = WakeupRecorder::WakeupRecorder()
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer, auto_wakeup=true)
  tools.wakeup = Some(wakeup_recorder_port(recorder))
  seed_undelivered(tools, task_id="task_1", child_session="subagent-1")
  tools.observe_ready(
    outcome_ready_event(task_id="task_1", session="parent_bg"),
  )
  assert_eq(recorder.requests, [("parent_bg", BACKGROUND_WAKEUP_TAG)])
  // Foreign receipts and malformed payloads never schedule a turn.
  tools.observe_ready(outcome_ready_event(task_id="other", session="parent_bg"))
  tools.observe_ready(outcome_ready_event(task_id="task_1", session=""))
  tools.observe_ready(
    @posoco.TurnEvent::Custom(
      source="posoco.tasks",
      label="background_spawned",
      data=Json::object(Map::from_array([])),
    ),
  )
  assert_eq(recorder.requests.length(), 1)
}

///|
test "observe_ready_stays_lazy_without_policy_or_capability" {
  let recorder = WakeupRecorder::WakeupRecorder()
  // Default policy is off: no request even with the capability present.
  let composer = FakeComposer::FakeComposer(response_text="x")
  let policy_off = test_tools(composer=composer as &ChildComposer)
  policy_off.wakeup = Some(wakeup_recorder_port(recorder))
  seed_undelivered(policy_off, task_id="task_1", child_session="subagent-1")
  policy_off.observe_ready(
    outcome_ready_event(task_id="task_1", session="parent_bg"),
  )
  assert_eq(recorder.requests, [])
  // Policy on but no composed capability (host without wakeup): lazy again.
  let capable = test_tools(
    composer=composer as &ChildComposer,
    auto_wakeup=true,
  )
  seed_undelivered(capable, task_id="task_1", child_session="subagent-1")
  capable.observe_ready(
    outcome_ready_event(task_id="task_1", session="parent_bg"),
  )
  assert_eq(recorder.requests, [])
}

///|
/// Seed one registered child with a recorded spawning session, mirroring the
/// spawn-time registry insert (question-side wakeup targets that session).
fn seed_registered_child(
  tools : SubagentTools,
  child_session~ : String,
  session~ : String,
) -> Unit {
  tools.registry[child_session] = BackgroundRecord::BackgroundRecord(
    kind="coder",
    session~,
  )
}

///|
test "queued_question_requests_wakeup_for_spawning_session" {
  let recorder = WakeupRecorder::WakeupRecorder()
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer, auto_wakeup=true)
  tools.wakeup = Some(wakeup_recorder_port(recorder))
  seed_registered_child(tools, child_session="subagent-1", session="parent_bg")
  ignore(
    tools.question.register(
      "subagent-1",
      "call-1",
      @posoco.UiRequest::Input(prompt="blocked?", default=None),
    ),
  )
  assert_eq(recorder.requests, [("parent_bg", QUESTION_WAKEUP_TAG)])
  match tools.registry.get("subagent-1") {
    Some(record) => assert_true(record.state is WaitingReply("question-1"))
    None => fail("child must stay registered")
  }
}

///|
test "armed_race_question_never_requests_wakeup" {
  let recorder = WakeupRecorder::WakeupRecorder()
  let composer = FakeComposer::FakeComposer(response_text="x")
  let tools = test_tools(composer=composer as &ChildComposer, auto_wakeup=true)
  tools.wakeup = Some(wakeup_recorder_port(recorder))
  seed_registered_child(tools, child_session="subagent-1", session="parent_bg")
  ignore(tools.question.arm("subagent-1"))
  ignore(
    tools.question.register(
      "subagent-1",
      "call-1",
      @posoco.UiRequest::Input(prompt="in-wave?", default=None),
    ),
  )
  // The live spawning-tool race carries this question in its receipt: no
  // queue, no wakeup, registry projection stays with the race.
  assert_eq(recorder.requests, [])
  match tools.registry.get("subagent-1") {
    Some(record) => assert_true(record.state is Running)
    None => fail("child must stay registered")
  }
}

///|
test "queued_question_wakeup_gates_and_fallbacks" {
  let recorder = WakeupRecorder::WakeupRecorder()
  let composer = FakeComposer::FakeComposer(response_text="x")
  // Policy off: the registry still projects WaitingReply, but no request.
  let policy_off = test_tools(composer=composer as &ChildComposer)
  policy_off.wakeup = Some(wakeup_recorder_port(recorder))
  seed_registered_child(policy_off, child_session="subagent-1", session="p1")
  ignore(
    policy_off.question.register(
      "subagent-1",
      "call-1",
      @posoco.UiRequest::Input(prompt="q?", default=None),
    ),
  )
  assert_eq(recorder.requests, [])
  match policy_off.registry.get("subagent-1") {
    Some(record) => assert_true(record.state is WaitingReply("question-1"))
    None => fail("child must stay registered")
  }
  // Policy on but no composed wakeup capability: lazy injection.
  let capability_less = test_tools(
    composer=composer as &ChildComposer,
    auto_wakeup=true,
  )
  seed_registered_child(
    capability_less,
    child_session="subagent-2",
    session="p2",
  )
  ignore(
    capability_less.question.register(
      "subagent-2",
      "call-2",
      @posoco.UiRequest::Input(prompt="q?", default=None),
    ),
  )
  assert_eq(recorder.requests, [])
  // No known session at all (record empty, no scoped event seen): skip.
  let session_less = test_tools(
    composer=composer as &ChildComposer,
    auto_wakeup=true,
  )
  session_less.wakeup = Some(wakeup_recorder_port(recorder))
  seed_registered_child(session_less, child_session="subagent-3", session="")
  ignore(
    session_less.question.register(
      "subagent-3",
      "call-3",
      @posoco.UiRequest::Input(prompt="q?", default=None),
    ),
  )
  assert_eq(recorder.requests, [])
}

///|
test "answer_echo_word_renders_each_question_type" {
  assert_eq(
    answer_echo_word(
      @posoco.UiRequest::Input(prompt="q", default=None),
      @posoco.UiResponse::Text("src/lib/agent.mbt"),
    ),
    "src/lib/agent.mbt",
  )
  assert_eq(
    answer_echo_word(
      @posoco.UiRequest::Confirm(prompt="go?"),
      @posoco.UiResponse::Yes,
    ),
    "true",
  )
  assert_eq(
    answer_echo_word(
      @posoco.UiRequest::Confirm(prompt="go?"),
      @posoco.UiResponse::No,
    ),
    "false",
  )
  assert_eq(
    answer_echo_word(
      @posoco.UiRequest::Select(
        prompt="pick",
        options=["alpha", "beta"],
        default=None,
      ),
      @posoco.UiResponse::Selected(1),
    ),
    "beta (index 1)",
  )
}
