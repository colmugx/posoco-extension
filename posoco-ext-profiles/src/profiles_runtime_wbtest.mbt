///|
/// ——— runtime tests: meta tool / hook / usage / commands / menu ———
///
/// Reuses the fakes from profiles_wbtest.mbt (same package): user_msg,
/// activate_call, assistant_with_calls, tool_result, manifest_json,
/// InMemoryProfileStore.

///|
fn parsed_manifest(
  id : String,
  exts? : Array[String] = [],
) -> ProfileManifest raise Failure {
  match parse_profile_manifest(manifest_json(id, exts~)) {
    Ok(m) => m
    Err(msg) => fail("unexpected parse error: \{msg}")
  }
}

///|
/// A tool call as the model issued it. A non-empty `inner` renders the
/// lazytools gateway envelope (`tool_execute` + `tool` argument).
fn usage_call(name~ : String, inner? : String = "") -> @posoco.ToolCall {
  let arguments : Json = if inner == "" {
    Json::object(Map::from_array([]))
  } else {
    Json::object(
      Map::from_array([
        ("tool", Json::string(inner)),
        ("arguments", Json::object(Map::from_array([]))),
      ]),
    )
  }
  {
    call_id: @posoco.CallId::unchecked("uc"),
    name: @posoco.ToolName::unchecked(name),
    arguments,
  }
}

///|
fn result_event(
  call : @posoco.ToolCall,
  is_error? : Bool = false,
) -> @posoco.TurnEvent {
  @posoco.TurnEvent::ToolCallResult(
    call~,
    result=@posoco.tk_ok_result("ok"),
    is_error~,
  )
}

///|
fn scope_for(session_id : String) -> @posoco.EventScope {
  {
    session_id: @posoco.SessionId::unchecked(session_id),
    run_id: @posoco.RunId::unchecked("r1"),
    turn_id: @posoco.TurnId::unchecked("t1"),
  }
}

///|
priv struct RecordingBus {
  events : Array[@devkit.BusEvent]
}

///|
fn RecordingBus::RecordingBus() -> RecordingBus {
  { events: [], }
}

///|
impl @devkit.BusSubscriber for RecordingBus with fn on_bus_event(
  self : RecordingBus,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
/// ——— activate_profile meta tool ———

///|
async test "activate_profile_unknown_id_enumerates_all_and_catalog" {
  let profiles = Profiles::build(
    manifests=[parsed_manifest("moonbit"), parsed_manifest("web")],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([]),
  )
  match
    profiles.execute("activate_profile", activate_call("c1", profile="nope")) {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_eq(first_line(content), "unknown profile: nope")
      assert_true(content.contains("available: all, moonbit, web"))
    }
    _ => fail("unknown id must answer Success with the enumeration")
  }
}

///|
async test "activate_profile_known_id_first_line_contract" {
  let profiles = Profiles::build(
    manifests=[parsed_manifest("moonbit")],
    defer_set=["nmem"],
    captured_prompts=Map::from_array([("nmem", "NMem manual.")]),
    attribution=Map::from_array([]),
  )
  match
    profiles.execute("activate_profile", activate_call("c1", profile="moonbit")) {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_eq(first_line(content), "activated: moonbit")
      // F7 wording: the manual rides the next model request — never
      // "wait for the next user message".
      assert_true(content.contains("next model request"))
      assert_true(content.contains("within this turn"))
    }
    _ => fail("known id must answer Success")
  }
}

///|
async test "activate_profile_bad_arguments_report_error" {
  let profiles = Profiles::build(
    manifests=[],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([]),
  )
  let malformed : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("c1"),
    name: @posoco.ToolName::unchecked("activate_profile"),
    arguments: Json::object(Map::from_array([])),
  }
  match profiles.execute("activate_profile", malformed) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("\"profile\""))
    _ => fail("bad arguments must answer ToolReportedError")
  }
  let raised : Result[@posoco.ToolOutcome, Error] = Ok(
    profiles.execute("other_tool", malformed),
  ) catch {
    error => Err(error)
  }
  match raised {
    Err(_) => ()
    Ok(_) => fail("a foreign tool name must raise")
  }
}

///|
/// ——— before_model hook ———

///|
async test "hook_injects_manual_with_coverage_and_resident_line" {
  let profiles = Profiles::build(
    manifests=[parsed_manifest("moonbit", exts=["nmem", "identity"])],
    defer_set=["nmem"],
    captured_prompts=Map::from_array([("nmem", "NMem manual.")]),
    attribution=Map::from_array([("scan", "identity")]),
  )
  let messages : Array[@posoco.Message] = [
    user_msg("do things"),
    assistant_with_calls([activate_call("c1", profile="moonbit")]),
    tool_result("c1", "activated: moonbit"),
  ]
  let out = profiles.before_model(messages)
  assert_eq(out.length(), 4)
  match out[3] {
    @posoco.Message::UserMessage(content~) =>
      match content {
        [@posoco.Content::Text(text), ..] => {
          assert_true(text.has_prefix("profile moonbit activated\n\n"))
          // Q19 coverage: the deferred member's manual is injected...
          assert_true(text.contains("NMem manual."))
          // ...the resident member is only listed, never re-injected.
          assert_true(
            text.contains("already resident (no re-injection): identity"),
          )
        }
        _ => fail("expected a Text payload")
      }
    _ => fail("expected UserMessage")
  }
}

///|
async test "hook_does_not_reinject_once_header_present" {
  let profiles = Profiles::build(
    manifests=[parsed_manifest("moonbit", exts=["nmem"])],
    defer_set=["nmem"],
    captured_prompts=Map::from_array([("nmem", "NMem manual.")]),
    attribution=Map::from_array([]),
  )
  let messages : Array[@posoco.Message] = [
    assistant_with_calls([activate_call("c1", profile="moonbit")]),
    tool_result("c1", "activated: moonbit"),
  ]
  let first = profiles.before_model(messages)
  assert_eq(first.length(), 3)
  // The injected header satisfies the scan — a second pass is a no-op.
  let second = profiles.before_model(first)
  assert_eq(second.length(), 3)
}

///|
async test "hook_all_activates_every_deferred_member" {
  let profiles = Profiles::build(
    manifests=[],
    defer_set=["a", "b"],
    captured_prompts=Map::from_array([("a", "Manual A."), ("b", "Manual B.")]),
    attribution=Map::from_array([]),
  )
  let messages : Array[@posoco.Message] = [
    assistant_with_calls([activate_call("c1", profile="all")]),
    tool_result("c1", "activated: all"),
  ]
  let out = profiles.before_model(messages)
  assert_eq(out.length(), 3)
  match out[2] {
    @posoco.Message::UserMessage(content~) =>
      match content {
        [@posoco.Content::Text(text), ..] => {
          assert_true(text.has_prefix("profile all activated\n\n"))
          assert_true(text.contains("Manual A."))
          assert_true(text.contains("Manual B."))
          assert_false(text.contains("already resident"))
        }
        _ => fail("expected a Text payload")
      }
    _ => fail("expected UserMessage")
  }
}

///|
async test "hook_publishes_bus_event_on_injection_only" {
  let bus = @devkit.EventBus::EventBus()
  let recorder = RecordingBus::RecordingBus()
  bus.subscribe(recorder)
  let profiles = Profiles::build(
    manifests=[parsed_manifest("moonbit", exts=["nmem"])],
    defer_set=["nmem"],
    captured_prompts=Map::from_array([("nmem", "NMem manual.")]),
    attribution=Map::from_array([]),
    bus=Some(bus),
  )
  let messages : Array[@posoco.Message] = [
    assistant_with_calls([activate_call("c1", profile="moonbit")]),
    tool_result("c1", "activated: moonbit"),
  ]
  let _ = profiles.before_model(messages)
  assert_eq(recorder.events.length(), 1)
  let event = recorder.events[0]
  assert_eq(event.source, "posoco_ext_profiles")
  assert_eq(event.topic, "profiles.activated")
  assert_true(event.data.stringify().contains("\"id\":\"moonbit\""))
  assert_true(event.data.stringify().contains("\"members\":[\"nmem\"]"))
  // The satisfied transcript stays silent on the next pass.
  let _ = profiles.before_model(messages)
  assert_eq(recorder.events.length(), 1)
}

///|
/// ——— usage attribution ———

///|
test "usage_counts_wrapped_gateway_calls_by_inner_name" {
  let profiles = Profiles::build(
    manifests=[],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([
      ("mcp_search", "ext_mcp"),
      ("mcp_send", "ext_mcp"),
    ]),
  )
  let wrapped = usage_call(name="tool_execute", inner="mcp_search")
  profiles.on_event_at(Some(scope_for("s1")), result_event(wrapped))
  profiles.on_event_at(Some(scope_for("s1")), result_event(wrapped))
  profiles.on_event_at(
    Some(scope_for("s1")),
    result_event(usage_call(name="tool_execute", inner="mcp_send")),
  )
  // Both inner names fold into the same owning ext.
  assert_eq(profiles.session_usage("s1"), [("ext_mcp", 3)])
}

///|
test "usage_counts_direct_calls_skips_errors_unattributed_unscoped" {
  let profiles = Profiles::build(
    manifests=[],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([
      ("mcp_search", "ext_a"),
      ("direct_tool", "ext_b"),
    ]),
  )
  // Direct (non-gateway) calls attribute by their own name.
  profiles.on_event_at(
    Some(scope_for("s1")),
    result_event(usage_call(name="direct_tool")),
  )
  profiles.on_event_at(
    Some(scope_for("s1")),
    result_event(usage_call(name="direct_tool")),
  )
  profiles.on_event_at(
    Some(scope_for("s1")),
    result_event(usage_call(name="mcp_search")),
  )
  // Failed executions never count.
  profiles.on_event_at(
    Some(scope_for("s1")),
    result_event(usage_call(name="mcp_search"), is_error=true),
  )
  // Unattributed tool names are dropped.
  profiles.on_event_at(
    Some(scope_for("s1")),
    result_event(usage_call(name="mystery")),
  )
  // Out-of-run diagnostics carry no scope — nothing to attribute to.
  profiles.on_event_at(None, result_event(usage_call(name="mcp_search")))
  // Count descending, deterministic tie-break by ext id.
  assert_eq(profiles.session_usage("s1"), [("ext_b", 2), ("ext_a", 1)])
}

///|
test "usage_isolates_sessions" {
  let profiles = Profiles::build(
    manifests=[],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([("mcp_search", "ext_mcp")]),
  )
  profiles.on_event_at(
    Some(scope_for("s1")),
    result_event(usage_call(name="mcp_search")),
  )
  profiles.on_event_at(
    Some(scope_for("s2")),
    result_event(usage_call(name="mcp_search")),
  )
  assert_eq(profiles.session_usage("s1"), [("ext_mcp", 1)])
  assert_eq(profiles.session_usage("s2"), [("ext_mcp", 1)])
  assert_eq(profiles.session_usage("s3"), [])
}

///|
/// ——— /profiles and /profile save commands ———

///|
async test "profiles_command_without_ui_fails" {
  let profiles = Profiles::build(
    manifests=[parsed_manifest("moonbit")],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([]),
  )
  match profiles.invoke("profiles", Json::object(Map::from_array([]))) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("UI"))
    _ => fail("missing ui must fail")
  }
}

///|
async test "profiles_command_select_appends_activation_message" {
  let store = @posoco.RecordingSessionStore()
  store.seed("s1", {
    messages: [user_msg("hi")],
    metadata: Map::from_array([]),
  })
  let ui = @posoco.RecordingUiPort(responses=[@posoco.UiResponse::Selected(0)])
  let profiles = Profiles::build(
    manifests=[parsed_manifest("moonbit", exts=["nmem"])],
    defer_set=["nmem"],
    captured_prompts=Map::from_array([("nmem", "NMem manual.")]),
    attribution=Map::from_array([]),
    session_store=Some(store),
  )
  profiles.on_compose(
    @posoco.tk_view(
      requires=[@posoco.Capability::Ui],
      model=@posoco.ScriptedModel::ScriptedModel([]),
      ui~,
    ),
  )
  match
    profiles.invoke(
      "profiles",
      Json::object(Map::from_array([("session_id", Json::string("s1"))])),
    ) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_eq(feedback, "activated profile: moonbit")
    _ => fail("selection must activate")
  }
  // The activation message — the same template the hook injects — was
  // appended at the transcript tail.
  let mut saw_append = false
  for op in store.ops() {
    match op {
      @posoco.SessionOp::OpAppend(id="s1", messages~, ..) => {
        saw_append = true
        assert_eq(messages.length(), 1)
        match messages[0] {
          @posoco.Message::UserMessage(content~) =>
            match content {
              [@posoco.Content::Text(text), ..] => {
                assert_true(text.has_prefix("profile moonbit activated\n\n"))
                assert_true(text.contains("NMem manual."))
              }
              _ => fail("expected a Text payload")
            }
          _ => fail("expected UserMessage")
        }
      }
      _ => ()
    }
  }
  assert_true(saw_append)
}

///|
async test "profiles_command_cancelled_fails" {
  let ui = @posoco.RecordingUiPort(responses=[@posoco.UiResponse::Cancelled])
  let profiles = Profiles::build(
    manifests=[parsed_manifest("moonbit")],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([]),
  )
  profiles.on_compose(
    @posoco.tk_view(
      requires=[@posoco.Capability::Ui],
      model=@posoco.ScriptedModel::ScriptedModel([]),
      ui~,
    ),
  )
  match
    profiles.invoke(
      "profiles",
      Json::object(Map::from_array([("session_id", Json::string("s1"))])),
    ) {
    @posoco.CommandOutcome::Failure(reason~) => assert_eq(reason, "cancelled")
    _ => fail("cancelled selection must fail")
  }
}

///|
async test "profiles_command_selection_without_wiring_fails" {
  let ui = @posoco.RecordingUiPort(responses=[@posoco.UiResponse::Selected(0)])
  // No session store wired at all.
  let profiles = Profiles::build(
    manifests=[parsed_manifest("moonbit")],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([]),
  )
  profiles.on_compose(
    @posoco.tk_view(
      requires=[@posoco.Capability::Ui],
      model=@posoco.ScriptedModel::ScriptedModel([]),
      ui~,
    ),
  )
  match
    profiles.invoke(
      "profiles",
      Json::object(Map::from_array([("session_id", Json::string("s1"))])),
    ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("host wiring"))
    _ => fail("selection without a store must fail")
  }
  // Store wired, but args carry no session_id.
  let store = @posoco.RecordingSessionStore()
  let ui2 = @posoco.RecordingUiPort(responses=[@posoco.UiResponse::Selected(0)])
  let profiles2 = Profiles::build(
    manifests=[parsed_manifest("moonbit")],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([]),
    session_store=Some(store),
  )
  profiles2.on_compose(
    @posoco.tk_view(
      requires=[@posoco.Capability::Ui],
      model=@posoco.ScriptedModel::ScriptedModel([]),
      ui=ui2,
    ),
  )
  match profiles2.invoke("profiles", Json::object(Map::from_array([]))) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("host wiring"))
    _ => fail("selection without a session_id must fail")
  }
}

///|
async test "profile_save_writes_store_and_catalog_visible" {
  let store = InMemoryProfileStore::InMemoryProfileStore()
  let profiles = Profiles::build(
    manifests=[],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([("mcp_search", "ext_mcp")]),
    store=Some(store),
  )
  profiles.on_event_at(
    Some(scope_for("s1")),
    result_event(usage_call(name="tool_execute", inner="mcp_search")),
  )
  match
    profiles.invoke(
      "profile",
      Json::object(
        Map::from_array([
          ("action", Json::string("save")),
          ("session_id", Json::string("s1")),
        ]),
      ),
    ) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_eq(feedback, "saved profile: session-ext-mcp")
    _ => fail("save must succeed")
  }
  match store.read_all() {
    Ok(pairs) => {
      assert_eq(pairs.length(), 1)
      let (level, raw) = pairs[0]
      assert_eq(level, "user")
      match parse_profile_manifest(@json.parse(raw)) {
        Ok(m) => {
          assert_eq(m.id, "session-ext-mcp")
          assert_eq(m.name, "session-ext_mcp")
          assert_eq(m.exts, ["ext_mcp"])
          assert_true(m.description.contains("auto-saved from session usage"))
        }
        Err(msg) => fail("stored manifest must re-parse: \{msg}")
      }
    }
    Err(msg) => fail("unexpected read error: \{msg}")
  }
  // Q19: the saved manifest is activatable through the meta tool in the
  // same session, without recomposition.
  match
    profiles.execute(
      "activate_profile",
      activate_call("c9", profile="session-ext-mcp"),
    ) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_eq(first_line(content), "activated: session-ext-mcp")
    _ => fail("saved profile must be activatable immediately")
  }
  // A repeat save over the same usage mints a collision-free id.
  match
    profiles.invoke(
      "profile",
      Json::object(
        Map::from_array([
          ("action", Json::string("save")),
          ("session_id", Json::string("s1")),
        ]),
      ),
    ) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_eq(feedback, "saved profile: session-ext-mcp-2")
    _ => fail("second save must succeed with a suffix")
  }
}

///|
async test "profile_save_summarizer_overrides_derivation" {
  let store = InMemoryProfileStore::InMemoryProfileStore()
  let profiles = Profiles::build(
    manifests=[],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([("mcp_search", "ext_mcp")]),
    store=Some(store),
    summarizer=Some(fn(_usage) { ("moonbit-dev", "MoonBit work mode") }),
  )
  profiles.on_event_at(
    Some(scope_for("s1")),
    result_event(usage_call(name="mcp_search")),
  )
  match
    profiles.invoke(
      "profile",
      Json::object(
        Map::from_array([
          ("action", Json::string("save")),
          ("session_id", Json::string("s1")),
        ]),
      ),
    ) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_eq(feedback, "saved profile: moonbit-dev")
    _ => fail("save must succeed")
  }
  match store.read_all() {
    Ok(pairs) =>
      match parse_profile_manifest(@json.parse(pairs[0].1)) {
        Ok(m) => {
          assert_eq(m.name, "moonbit-dev")
          assert_eq(m.description, "MoonBit work mode")
          assert_eq(m.exts, ["ext_mcp"])
        }
        Err(msg) => fail("stored manifest must re-parse: \{msg}")
      }
    Err(msg) => fail("unexpected read error: \{msg}")
  }
}

///|
async test "profile_save_without_usage_or_session_fails" {
  let profiles = Profiles::build(
    manifests=[],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([("mcp_search", "ext_mcp")]),
  )
  match
    profiles.invoke(
      "profile",
      Json::object(
        Map::from_array([
          ("action", Json::string("save")),
          ("session_id", Json::string("s1")),
        ]),
      ),
    ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_eq(reason, "no tool usage recorded for this session")
    _ => fail("empty usage must fail")
  }
  match
    profiles.invoke(
      "profile",
      Json::object(Map::from_array([("action", Json::string("save"))])),
    ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("session_id"))
    _ => fail("missing session_id must fail")
  }
}

///|
/// ——— system-prompt menu ———

///|
test "menu_lists_fallback_sentence_rows_and_dangling_suffix_stably" {
  let profiles = Profiles::build(
    manifests=[
      parsed_manifest("moonbit"),
      parsed_manifest("web", exts=["missing_ext"]),
    ],
    defer_set=["nmem"],
    captured_prompts=Map::from_array([("nmem", "NMem manual.")]),
    attribution=Map::from_array([("mcp_search", "ext_mcp")]),
  )
  let prompt = profiles.system_prompt()
  assert_true(prompt.has_prefix("## Profiles"))
  assert_true(prompt.contains("when no profile matches, activate `all`"))
  assert_true(prompt.contains("- moonbit: Working on MoonBit services"))
  assert_true(
    prompt.contains(
      "- web: Working on MoonBit services (dangling: missing_ext)",
    ),
  )
  // Byte stability: two reads, same bytes.
  assert_eq(prompt, profiles.system_prompt())
  // Q13 warnings surface for hosts as well.
  assert_eq(profiles.warnings().length(), 1)
}

///|
test "menu_truncates_long_descriptions" {
  let mut long = ""
  for _i in 0..<200 {
    long = long + "x"
  }
  let manifest : ProfileManifest = {
    id: "long",
    name: "Long",
    description: long,
    exts: [],
  }
  let profiles = Profiles::build(
    manifests=[manifest],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([]),
  )
  let prompt = profiles.system_prompt()
  assert_false(prompt.contains("- long: \{long}"))
  assert_true(prompt.contains("- long: \{long[0:160].to_owned()}..."))
}
