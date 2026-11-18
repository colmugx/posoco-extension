///|
/// ——— Shared fixtures ———
const WEBFETCH_OWNER : String = "posoco_ext_webfetch"

///|
fn webfetch_provider() -> @tk.RecordingToolProvider {
  @tk.RecordingToolProvider(
    [
      @tk.tk_tool_def(
        "webfetch_url", "Fetch a URL and return its readable body",
      ),
    ],
    Map::from_array([
      (
        "webfetch_url",
        @tk.ScriptedToolOutcome::OutcomeOk(@tk.tk_ok_result("fetched body")),
      ),
    ]),
  )
}

///|
fn gateway() -> LazyTools {
  match
    LazyTools::new(groups=[{ owner: WEBFETCH_OWNER, hint: "fetch URLs", }]) {
    Ok(ext) => ext
    Err(message) => abort("unexpected defer error: " + message)
  }
}

///|
fn turn_agent(
  model : @tk.ScriptedModel,
  provider : &@posoco.ToolProvider,
  ext : LazyTools,
) -> @posoco.Agent raise @posoco.CompositionError {
  @posoco.Agent(
    events=@posoco.EventSystem(),
    exts=[
      @tk.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      @tk.tk_ext(id=WEBFETCH_OWNER, tools=[provider]),
      ext,
    ],
    config=@tk.tk_config(),
  )
}

///|
fn tool_names(defs : Array[@kernel.ToolDef]) -> Array[String] {
  defs.map(fn(def) { def.name.to_string() })
}

///|
/// ——— Construction and the model-visible surface ———

///|
test "meta_surface_is_exactly_the_two_gateway_tools" {
  let defs = gateway().list_tools()
  assert_eq(defs.length(), 2)
  assert_eq(defs[0].name.to_string(), "tool_list")
  assert_eq(defs[1].name.to_string(), "tool_execute")
  assert_true(defs[0].policy is @posoco.ExecutionPolicy::Parallel)
  assert_true(defs[1].policy is @posoco.ExecutionPolicy::Sequential)
}

///|
test "new_rejects_empty_and_duplicate_owner" {
  match LazyTools::new(groups=[{ owner: "", hint: "nameless", }]) {
    Err(message) => assert_true(message.contains("empty owner"))
    Ok(_) => fail("expected an empty-owner error")
  }
  match
    LazyTools::new(groups=[
      { owner: "posoco_ext_a", hint: "one", },
      { owner: "posoco_ext_a", hint: "two", },
    ]) {
    Err(message) => assert_true(message.contains("duplicate deferred owner"))
    Ok(_) => fail("expected a duplicate-owner error")
  }
}

///|
test "exposure_defers_declared_owner_only" {
  let ext = gateway()
  let deferred : @posoco.ToolDef = @tk.tk_tool_def("webfetch_url", "Fetch")
  let deferred = {
    ..deferred,
    owner: @posoco.OwnerId::unchecked(WEBFETCH_OWNER),
  }
  assert_true(ext.tool_exposure(deferred) is @posoco.ToolExposure::Deferred)
  let resident = {
    ..deferred,
    owner: @posoco.OwnerId::unchecked("posoco_ext_read"),
  }
  assert_true(ext.tool_exposure(resident) is @posoco.ToolExposure::Direct)
  for def in ext.list_tools() {
    assert_true(ext.tool_exposure(def) is @posoco.ToolExposure::Direct)
  }
}

///|
async test "model_request_hides_deferred_schema_but_keeps_meta_tools" {
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("done")),
  ])
  let provider = webfetch_provider()
  let agent = turn_agent(model, provider, gateway()) catch {
    error => fail("composition failed: \{error}")
  }
  let _ = agent.run_turn(@tk.tk_user_msg("hello"), "s1") catch {
    error => fail("turn failed: \{error}")
  }
  let sent = tool_names(model.received_tools[0])
  assert_true(sent.contains("tool_list"))
  assert_true(sent.contains("tool_execute"))
  assert_false(sent.contains("webfetch_url"))
}

///|
async test "direct_call_to_deferred_tool_is_not_offered" {
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(
      @tk.tk_tool_call_response("webfetch_url", "call_1", {
        "url": "https://example.com",
      }),
    ),
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("done")),
  ])
  let provider = webfetch_provider()
  let agent = turn_agent(model, provider, gateway()) catch {
    error => fail("composition failed: \{error}")
  }
  let result = agent.run_turn(@tk.tk_user_msg("fetch it"), "s1") catch {
    error => fail("turn failed: \{error}")
  }
  assert_eq(result.tool_results.length(), 1)
  match result.tool_results[0] {
    @posoco.ToolOutcome::NotExecuted(reason~, ..) =>
      assert_true(reason.to_string().contains("NotOffered"))
    _ => fail("expected a NotExecuted(NotOffered) outcome")
  }
  // The definition lives in the catalog (it was validated as known), so the
  // provider must never have been entered.
  assert_eq(provider.exec_records().length(), 0)
}

///|
async test "tool_list_reports_the_deferred_group_with_its_schema" {
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(
      @tk.tk_tool_call_response("tool_list", "call_1", {}),
    ),
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("done")),
  ])
  let provider = webfetch_provider()
  let agent = turn_agent(model, provider, gateway()) catch {
    error => fail("composition failed: \{error}")
  }
  let result = agent.run_turn(@tk.tk_user_msg("what can you fetch"), "s1") catch {
    error => fail("turn failed: \{error}")
  }
  match result.tool_results[0] {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_true(content.contains("webfetch"))
      assert_true(content.contains("webfetch_url"))
      assert_true(content.contains("input_schema"))
    }
    _ => fail("expected tool_list to succeed")
  }
}

///|
async test "tool_execute_runs_the_child_through_the_kernel" {
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(
      @tk.tk_tool_call_response("tool_execute", "call_1", {
        "tool": "webfetch_url",
        "arguments": { "url": "https://example.com" },
      }),
    ),
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("done")),
  ])
  let provider = webfetch_provider()
  let agent = turn_agent(model, provider, gateway()) catch {
    error => fail("composition failed: \{error}")
  }
  let result = agent.run_turn(@tk.tk_user_msg("fetch example.com"), "s1") catch {
    error => fail("turn failed: \{error}")
  }
  match result.tool_results[0] {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_eq(content, "fetched body")
    _ => fail("expected the child's success to pass through verbatim")
  }
  let records = provider.exec_records()
  assert_eq(records.length(), 1)
  assert_eq(records[0].tool_name, "webfetch_url")
}

///|
async test "tool_execute_steers_on_a_name_outside_the_face" {
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(
      @tk.tk_tool_call_response("tool_execute", "call_1", {
        "tool": "not_a_tool",
      }),
    ),
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("done")),
  ])
  let provider = webfetch_provider()
  let agent = turn_agent(model, provider, gateway()) catch {
    error => fail("composition failed: \{error}")
  }
  let result = agent.run_turn(@tk.tk_user_msg("run something"), "s1") catch {
    error => fail("turn failed: \{error}")
  }
  match result.tool_results[0] {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("Unknown deferred tool"))
    _ => fail("expected a ToolReportedError outcome")
  }
  assert_eq(provider.exec_records().length(), 0)
}

///|
/// ——— A group published after composition ———

///|
/// Publishes its tool group during `on_start`, i.e. after `LazyTools::new` has
/// already been composed. The first operation captures the catalog after
/// `on_start`, so deferral must cover it without any LazyTools refresh.
priv struct LatePublisher {
  provider : @tk.RecordingToolProvider
  mut contributions : @posoco.ToolContributions?
}

///|
impl @posoco.Extension for LatePublisher with fn extension_id(_self) -> String {
  "posoco_ext_late"
}

///|
impl @posoco.Extension for LatePublisher with fn manifest(self : LatePublisher) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="posoco_ext_late", lifecycle=[self], requires=[
    @posoco.Capability::ToolContribution,
  ])
}

///|
impl @posoco.Lifecycle for LatePublisher with fn on_compose(
  self : LatePublisher,
  view : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.contributions = view.tool_contributions()
}

///|
impl @posoco.Lifecycle for LatePublisher with fn on_start(self : LatePublisher) -> Unit {
  match self.contributions {
    // Publication before the first operation's capture is what makes the
    // group deferrable without a composition-time snapshot.
    Some(capability) => {
      let _ = capability.replace(
        provider=self.provider as &@posoco.ToolProvider,
      )
    }
    None => ()
  }
}

///|
async test "dynamic_group_published_after_composition_is_deferred" {
  let provider = @tk.RecordingToolProvider(
    [@tk.tk_tool_def("late_echo", "Echo a value from a runtime toolkit")],
    Map::from_array([
      ("late_echo", @tk.ScriptedToolOutcome::OutcomeOk(@tk.tk_ok_result("ok"))),
    ]),
  )
  let publisher : LatePublisher = { provider, contributions: None, }
  let ext = match
    LazyTools::new(groups=[
      { owner: "posoco_ext_late", hint: "runtime toolkit", },
    ]) {
    Ok(ext) => ext
    Err(message) => abort("unexpected defer error: " + message)
  }
  let model = @tk.ScriptedModel([
    @tk.ScriptedModelStep::Respond(
      @tk.tk_tool_call_response("late_echo", "call_1", {}),
    ),
    @tk.ScriptedModelStep::Respond(
      @tk.tk_tool_call_response("tool_execute", "call_2", {
        "tool": "late_echo",
      }),
    ),
    @tk.ScriptedModelStep::Respond(@tk.tk_stop_response("done")),
  ])
  let agent = @posoco.Agent(
    events=@posoco.EventSystem(),
    exts=[
      @tk.tk_ext(id="model", model=Some(model as &@posoco.ModelPort)),
      publisher,
      ext,
    ],
    config=@tk.tk_config(),
  ) catch {
    error => fail("composition failed: \{error}")
  }
  let result = agent.run_turn(@tk.tk_user_msg("echo"), "s1") catch {
    error => fail("turn failed: \{error}")
  }
  assert_false(tool_names(model.received_tools[0]).contains("late_echo"))
  match result.tool_results[0] {
    @posoco.ToolOutcome::NotExecuted(reason~, ..) =>
      assert_true(reason.to_string().contains("NotOffered"))
    _ => fail("expected the published group's direct call to be not offered")
  }
  // The gateway reaches the same group through the child pipeline.
  match result.tool_results[1] {
    @posoco.ToolOutcome::Success(content~, ..) => assert_eq(content, "ok")
    _ => fail("expected tool_execute to reach the late-published tool")
  }
}

///|
/// ——— Resident prompt section ———

///|
test "prompt_section_lists_owner_groups_with_hints" {
  let prompt = gateway().system_prompt()
  assert_true(prompt.contains("## Deferred tools"))
  assert_true(prompt.contains("- webfetch: fetch URLs"))
  assert_true(prompt.contains("tool_list"))
  assert_true(prompt.contains("tool_execute"))
  assert_true(prompt.contains("Reuse a schema already shown by `tool_list`"))
  assert_true(prompt.contains("Do not rediscover schemas already in history"))
}

///|
test "manifest_declares_the_invocable_face_and_no_observers" {
  let manifest = gateway().manifest()
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.tool_call_owners, [WEBFETCH_OWNER])
  assert_eq(manifest.observers.length(), 0)
  assert_eq(manifest.prompt_contributors.length(), 1)
  assert_eq(manifest.hooks.length(), 2)
}

///|
test "prompt_section_is_identical_for_equal_declarations" {
  assert_eq(gateway().system_prompt(), gateway().system_prompt())
}

///|
test "prompt_section_matches_the_declared_owner_set" {
  let ext = match
    LazyTools::new(groups=[
      { owner: "posoco_ext_webfetch", hint: "fetch URLs", },
      { owner: "posoco_ext_mcp", hint: "configured MCP servers", },
    ]) {
    Ok(ext) => ext
    Err(message) => abort("unexpected defer error: " + message)
  }
  assert_eq(ext.deferred_owners(), ["posoco_ext_webfetch", "posoco_ext_mcp"])
  let prompt = ext.system_prompt()
  assert_true(prompt.contains("- webfetch: fetch URLs"))
  assert_true(prompt.contains("- mcp: configured MCP servers"))
}

///|
/// ——— Legacy transcript migration ———

///|
async test "legacy_envelope_is_removed_once" {
  let hooks = gateway().manifest().hooks
  assert_eq(hooks.length(), 2)
  let migration = hooks[0]
  let legacy : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(
      "<lazytools-context type=\"recent-tools\" trust=\"true\">grep</lazytools-context>",
    ),
  ])
  let keep : @posoco.Message = @tk.tk_user_msg("hello")
  let rewritten = migration.before_model([legacy, keep]) catch {
    _ => fail("migration hook must not abort the run")
  }
  assert_eq(rewritten.length(), 1)
  let untouched = migration.before_model([keep]) catch {
    _ => fail("migration hook must not abort the run")
  }
  assert_eq(untouched.length(), 1)
}
