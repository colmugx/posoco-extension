///|
/// ——— Test helpers ———

///|
fn deferred_def(name : String, description : String) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(name),
    description,
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "path": Json::object({
          "type": Json::string("string"),
          "description": Json::string("A path argument"),
        }),
      }),
      "required": Json::array([Json::string("path")]),
    }),
    owner: @posoco.OwnerId::unchecked("test_child"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("test_child"),
  }
}

///|
fn recording(
  defs : Array[@posoco.ToolDef],
  outcomes : Map[String, @posoco.ScriptedToolOutcome],
) -> @posoco.RecordingToolProvider {
  @posoco.RecordingToolProvider(defs, outcomes)
}

///|
fn build_ok(providers : Array[&@posoco.ToolProvider]) -> LazyTools raise {
  match LazyTools::build(providers~) {
    Ok(ext) => ext
    Err(msg) => fail("unexpected build error: \{msg}")
  }
}

///|
fn meta_call(name : String, args : Map[String, Json]) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("meta-1"),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object(args),
  }
}

///|
fn expect_success(outcome : @posoco.ToolOutcome) -> String raise {
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => content
    _ => fail("expected a Success outcome")
  }
}

///|
/// Feed one turn event to the gateway's observer view.
fn observe(ext : LazyTools, call : @posoco.ToolCall) -> Unit {
  (ext as &@posoco.Observer).on_event(
    @posoco.TurnEvent::ToolCallResult(
      call~,
      result=@posoco.ToolOutcome::Success(content="ok", structured=None),
      is_error=false,
    ),
  )
}

///|
/// ——— build: index and collision diagnostics ———

///|
test "build_rejects_deferred_name_collision" {
  let a = recording(
    [deferred_def("grep", "Search file contents")],
    Map::from_array([]),
  )
  let b = recording([deferred_def("grep", "Another grep")], Map::from_array([]))
  match LazyTools::build(providers=[a, b]) {
    Err(msg) => {
      assert_true(msg.contains("collision"))
      assert_true(msg.contains("'grep'"))
    }
    Ok(_) => fail("expected a deferred name collision error")
  }
}

///|
test "build_rejects_empty_tool_name" {
  let child = recording([deferred_def("", "nameless")], Map::from_array([]))
  match LazyTools::build(providers=[child]) {
    Err(msg) => assert_true(msg.contains("empty name"))
    Ok(_) => fail("expected an empty-name error")
  }
}

///|
/// ——— list_tools: the meta-tool surface ———

///|
test "list_tools_exposes_only_two_meta_tools_with_policies" {
  let child = recording(
    [deferred_def("read", "Read a file")],
    Map::from_array([]),
  )
  let ext = build_ok([child])
  let defs = ext.list_tools()
  assert_eq(defs.length(), 2)
  assert_eq(defs[0].name.to_string(), "tool_list")
  assert_eq(defs[1].name.to_string(), "tool_execute")
  assert_eq(defs[0].policy.to_string(), "Parallel")
  // Deferred side-effecting tools route through one meta tool; never share
  // a wave with anything else.
  assert_eq(defs[1].policy.to_string(), "Sequential")
  for def in defs {
    assert_eq(def.owner.to_string(), "posoco_ext_lazytools")
  }
  assert_eq(ext.deferred_count(), 1)
  assert_eq(ext.deferred_names(), ["read"])
}

///|
/// ——— tool_list: browse and keyword-search ———

///|
async test "tool_list_without_keyword_lists_every_group_with_schemas" {
  fn prov_def(name : String, prov : String) -> @posoco.ToolDef {
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked(name),
      description: "A deferred tool",
      input_schema: Json::object({ "type": Json::string("object") }),
      owner: @posoco.OwnerId::unchecked(prov),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some(prov),
    }
  }

  let web = recording(
    [prov_def("webfetch", "posoco_ext_webfetch")],
    Map::from_array([]),
  )
  let nmem = recording(
    [
      prov_def("memory_search", "posoco_ext_nowledge_mem"),
      prov_def("memory_add", "posoco_ext_nowledge_mem"),
    ],
    Map::from_array([]),
  )
  let ext = build_ok([web, nmem])
  let content = expect_success(
    ext.execute("tool_list", meta_call("tool_list", Map::from_array([]))),
  )
  assert_true(content.has_prefix("all 2 folded groups:"))
  // Grouped by provenance; display ids strip the packaging prefix.
  assert_true(content.contains("\"ext\": \"webfetch\""))
  assert_true(content.contains("\"ext\": \"nowledge_mem\""))
  // Every tool of a group comes back, with schema for direct execution.
  assert_true(content.contains("\"webfetch\""))
  assert_true(content.contains("\"memory_search\""))
  assert_true(content.contains("\"memory_add\""))
  assert_true(content.contains("input_schema"))
}

///|
async test "tool_list_keyword_returns_whole_matching_groups" {
  fn prov_def2(name : String, prov : String) -> @posoco.ToolDef {
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked(name),
      description: "A deferred tool",
      input_schema: Json::object({ "type": Json::string("object") }),
      owner: @posoco.OwnerId::unchecked(prov),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some(prov),
    }
  }

  let nmem = recording(
    [
      prov_def2("memory_search", "posoco_ext_nowledge_mem"),
      prov_def2("memory_add", "posoco_ext_nowledge_mem"),
    ],
    Map::from_array([]),
  )
  let obsidian = recording(
    [prov_def2("obsidian_search", "posoco_ext_obsidian")],
    Map::from_array([]),
  )
  let ext = build_ok([nmem, obsidian])
  // A keyword hit on tool names promotes the WHOLE group.
  let content = expect_success(
    ext.execute(
      "tool_list",
      meta_call(
        "tool_list",
        Map::from_array([("keyword", Json::string("memory"))]),
      ),
    ),
  )
  assert_true(content.contains("1 of 2 folded groups matched 'memory'"))
  assert_true(content.contains("\"memory_search\""))
  assert_true(content.contains("\"memory_add\""))
  assert_false(content.contains("obsidian_search"))
  // A keyword hit on the display id works too (posoco_ext_ stripped).
  let by_id = expect_success(
    ext.execute(
      "tool_list",
      meta_call(
        "tool_list",
        Map::from_array([("keyword", Json::string("nowledge_mem"))]),
      ),
    ),
  )
  assert_true(by_id.contains("1 of 2 folded groups matched 'nowledge_mem'"))
  assert_true(by_id.contains("\"memory_search\""))
  assert_false(by_id.contains("obsidian_search"))
}

///|
async test "tool_list_no_match_steers_to_full_browse" {
  let child = recording(
    [deferred_def("read", "Read a file")],
    Map::from_array([]),
  )
  let ext = build_ok([child])
  let content = expect_success(
    ext.execute(
      "tool_list",
      meta_call(
        "tool_list",
        Map::from_array([("keyword", Json::string("zzz"))]),
      ),
    ),
  )
  assert_true(content.contains("No folded tool group matches 'zzz'"))
  assert_true(content.contains("without arguments"))
}

///|
/// ——— tool_execute: routing and error mapping ———

///|
async test "tool_execute_routes_to_owner_and_preserves_call_id" {
  let outcomes : Map[String, @posoco.ScriptedToolOutcome] = Map::from_array([
    (
      "github_create_issue",
      @posoco.OutcomeOk(
        @posoco.ToolOutcome::Success(content="created #1", structured=None),
      ),
    ),
  ])
  let child = recording(
    [deferred_def("github_create_issue", "Create an issue")],
    outcomes,
  )
  let ext = build_ok([child])
  let outcome = ext.execute(
    "tool_execute",
    meta_call(
      "tool_execute",
      Map::from_array([
        ("tool", Json::string("github_create_issue")),
        (
          "arguments",
          Json::object(Map::from_array([("path", Json::string("/tmp/a"))])),
        ),
      ]),
    ),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_eq(content, "created #1")
    _ => fail("expected the child outcome to pass through")
  }
  let records = child.exec_records()
  assert_eq(records.length(), 1)
  assert_eq(records[0].requested_name, "github_create_issue")
  assert_eq(records[0].call_id, "meta-1")
  match records[0].arguments {
    Json::Object(args) =>
      assert_eq(args.get("path"), Some(Json::string("/tmp/a")))
    _ => fail("expected inner arguments to stay an object")
  }
}

///|
async test "tool_execute_defaults_missing_arguments_to_empty_object" {
  let outcomes : Map[String, @posoco.ScriptedToolOutcome] = Map::from_array([
    (
      "list_all",
      @posoco.OutcomeOk(
        @posoco.ToolOutcome::Success(content="ok", structured=None),
      ),
    ),
  ])
  let child = recording(
    [
      @posoco.ToolDef::{
        name: @posoco.ToolName::unchecked("list_all"),
        description: "Takes no arguments",
        input_schema: Json::object({
          "type": Json::string("object"),
          "properties": Json::object({}),
        }),
        owner: @posoco.OwnerId::unchecked("test_child"),
        policy: @posoco.ExecutionPolicy::Parallel,
        provenance: Some("test_child"),
      },
    ],
    outcomes,
  )
  let ext = build_ok([child])
  let _ = expect_success(
    ext.execute(
      "tool_execute",
      meta_call(
        "tool_execute",
        Map::from_array([("tool", Json::string("list_all"))]),
      ),
    ),
  )
  let records = child.exec_records()
  assert_eq(records.length(), 1)
  match records[0].arguments {
    Json::Object(args) => assert_eq(args.length(), 0)
    _ => fail("expected empty object arguments, not null")
  }
}

///|
async test "tool_execute_unknown_tool_is_tool_reported_error_with_steering" {
  let child = recording(
    [deferred_def("read", "Read a file")],
    Map::from_array([]),
  )
  let ext = build_ok([child])
  let outcome = ext.execute(
    "tool_execute",
    meta_call("tool_execute", Map::from_array([("tool", Json::string("nope"))])),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("Unknown deferred tool 'nope'"))
      assert_true(content.contains("tool_list"))
    }
    _ => fail("expected a ToolReportedError for the unknown deferred tool")
  }
}

///|
async test "child_runtime_error_propagates_verbatim" {
  let outcomes : Map[String, @posoco.ScriptedToolOutcome] = Map::from_array([
    (
      "read",
      @posoco.OutcomeErr(@posoco.RuntimeError::InvocationFailed("disk on fire")),
    ),
  ])
  let child = recording([deferred_def("read", "Read a file")], outcomes)
  let ext = build_ok([child])
  let outcome = Ok(
    ext.execute(
      "tool_execute",
      meta_call(
        "tool_execute",
        Map::from_array([("tool", Json::string("read"))]),
      ),
    ),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(@posoco.RuntimeError::InvocationFailed(msg)) =>
      assert_eq(msg, "disk on fire")
    _ => fail("expected the child RuntimeError to propagate")
  }
}

///|
/// ——— argument validation (house style: RuntimeError) ———

///|
async test "meta_argument_mistakes_raise_unknown_tool" {
  let child = recording(
    [deferred_def("read", "Read a file")],
    Map::from_array([]),
  )
  let ext = build_ok([child])
  // tool_execute: missing 'tool'
  let missing = Ok(
    ext.execute("tool_execute", meta_call("tool_execute", Map::from_array([]))),
  ) catch {
    error => Err(error)
  }
  match missing {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("missing 'tool'"))
    _ => fail("expected missing 'tool' to raise")
  }
  // tool_list: blank keyword
  let blank = Ok(
    ext.execute(
      "tool_list",
      meta_call(
        "tool_list",
        Map::from_array([("keyword", Json::string("   "))]),
      ),
    ),
  ) catch {
    error => Err(error)
  }
  match blank {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("at least one keyword"))
    _ => fail("expected a blank keyword to raise")
  }
}

///|
/// ——— gateway call convention ———

///|
test "unwrap_call_resolves_the_inner_identity" {
  let gateway_call = meta_call(
    "tool_execute",
    Map::from_array([
      ("tool", Json::string("bash")),
      (
        "arguments",
        Json::object(Map::from_array([("cmd", Json::string("ls -la"))])),
      ),
    ]),
  )
  let (name, inner) = LazyTools::unwrap_call(gateway_call)
  assert_eq(name, "bash")
  assert_eq(inner.name.to_string(), "bash")
  assert_eq(inner.call_id.to_string(), "meta-1")
  match inner.arguments {
    Json::Object(args) =>
      assert_eq(args.get("cmd"), Some(Json::string("ls -la")))
    _ => fail("expected unwrapped arguments")
  }
  // Non-gateway calls come back unchanged.
  let (direct_name, direct_call) = LazyTools::unwrap_call(
    meta_call("read", Map::from_array([])),
  )
  assert_eq(direct_name, "read")
  assert_eq(direct_call.name.to_string(), "read")
  // Malformed gateway calls classify as tool_execute itself.
  let (fallback_name, _) = LazyTools::unwrap_call(
    meta_call("tool_execute", Map::from_array([])),
  )
  assert_eq(fallback_name, "tool_execute")
}

///|
test "is_meta_tool_matches_only_the_two_meta_names" {
  assert_true(LazyTools::is_meta_tool("tool_list"))
  assert_true(LazyTools::is_meta_tool("tool_execute"))
  assert_false(LazyTools::is_meta_tool("read"))
  assert_false(LazyTools::is_meta_tool("bash"))
}

///|
test "rewrap_call_restores_the_outer_shape" {
  let gateway_call = meta_call(
    "tool_execute",
    Map::from_array([
      ("tool", Json::string("bash")),
      (
        "arguments",
        Json::object(
          Map::from_array([
            ("cmd", Json::string("ls")),
            ("x", Json::string("y")),
          ]),
        ),
      ),
    ]),
  )
  let (_, inner) = LazyTools::unwrap_call(gateway_call)
  let rewritten : @posoco.ToolCall = {
    call_id: inner.call_id,
    name: inner.name,
    arguments: Json::object(
      Map::from_array([
        ("cmd", Json::string("rtk ls")),
        ("x", Json::string("y")),
      ]),
    ),
  }
  let outer = LazyTools::rewrap_call(gateway_call, rewritten)
  assert_eq(outer.name.to_string(), "tool_execute")
  assert_eq(outer.call_id.to_string(), "meta-1")
  match outer.arguments {
    Json::Object(args) => {
      assert_eq(args.get("tool"), Some(Json::string("bash")))
      match args.get("arguments") {
        Some(Json::Object(inner_args)) => {
          assert_eq(inner_args.get("cmd"), Some(Json::string("rtk ls")))
          assert_eq(inner_args.get("x"), Some(Json::string("y")))
        }
        _ => fail("expected nested arguments object")
      }
    }
    _ => fail("expected outer arguments object")
  }
}

///|
/// ——— defer_extensions: whole-extension deferral ———

///|
/// Minimal extension fake: fixed id and a configurable tool-provider list.
priv struct FakeToolExt {
  id : String
  tools : Array[&@posoco.ToolProvider]
}

///|
impl @posoco.Extension for FakeToolExt with fn extension_id(self : FakeToolExt) -> String {
  self.id
}

///|
impl @posoco.Extension for FakeToolExt with fn manifest(self : FakeToolExt) -> @posoco.ExtensionManifest {
  {
    id: self.id,
    models: [],
    tools: self.tools,
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
test "defer_extensions_moves_tool_views_behind_the_gateway" {
  let child = recording(
    [deferred_def("nmem_status", "Memory status")],
    Map::from_array([]),
  )
  let ext : &@posoco.Extension = FakeToolExt::{
    id: "fake_nmem",
    tools: [child],
  }
  let toolless : &@posoco.Extension = FakeToolExt::{
    id: "fake_hook_only",
    tools: [],
  }
  let (gateway, views) = match
    LazyTools::defer_extensions(exts=[ext, toolless]) {
    Ok(pair) => pair
    Err(message) => fail("unexpected defer error: \{message}")
  }
  assert_eq(gateway.list_tools().length(), 2)
  assert_eq(gateway.deferred_count(), 1)
  assert_eq(views.length(), 2)
  assert_eq(views[0].extension_id(), "fake_nmem")
  assert_eq(views[0].manifest().tools.length(), 0)
  assert_eq(views[1].extension_id(), "fake_hook_only")
}

///|
test "defer_extensions_fails_on_cross_extension_tool_collision" {
  let a = recording([deferred_def("dup", "One")], Map::from_array([]))
  let b = recording([deferred_def("dup", "Two")], Map::from_array([]))
  let ext_a : &@posoco.Extension = FakeToolExt::{ id: "a", tools: [a], }
  let ext_b : &@posoco.Extension = FakeToolExt::{ id: "b", tools: [b], }
  match LazyTools::defer_extensions(exts=[ext_a, ext_b]) {
    Err(message) => assert_true(message.contains("collision"))
    Ok(_) => fail("expected a collision across deferred extensions")
  }
}

///|
/// ——— discoverability: the resident deferred-tools prompt ———

///|
test "system_prompt_lists_folded_groups_with_names_and_descriptions" {
  let web = recording(
    [deferred_def("webfetch", "Fetch a URL page")],
    Map::from_array([]),
  )
  let nmem = recording(
    [
      deferred_def("memory_search", "Search past memories"),
      deferred_def("memory_add", "Add a new memory"),
    ],
    Map::from_array([]),
  )
  let ext = build_ok([web, nmem])
  let manifest = ext.manifest()
  assert_eq(manifest.prompt_contributors.length(), 1)
  let prompt = manifest.prompt_contributors[0].system_prompt()
  assert_true(prompt.has_prefix("## Deferred tools"))
  assert_true(prompt.contains("you MUST look them up with `tool_list`"))
  assert_true(prompt.contains("then call the tool with `tool_execute`"))
  // Auto-concatenated tool names and descriptions per group.
  assert_true(
    prompt.contains(
      "- test_child: webfetch — Fetch a URL page; memory_search — Search past memories; memory_add — Add a new memory",
    ),
  )
}

///|
test "empty_gateway_prompt_says_the_fold_is_empty" {
  let empty = build_ok([])
  let prompt = empty.manifest().prompt_contributors[0].system_prompt()
  assert_true(prompt.contains("(no folded tools)"))
}

///|
/// ——— recent-tools: observer tracking + before_model hint ———

///|
fn gateway_execute_call(tool : String) -> @posoco.ToolCall {
  meta_call(
    "tool_execute",
    Map::from_array([
      ("tool", Json::string(tool)),
      ("arguments", Json::object(Map::from_array([]))),
    ]),
  )
}

///|
async test "observer_records_recent_deferred_usage_most_recent_first" {
  let child = recording(
    [
      deferred_def("bash", "Run a shell command"),
      deferred_def("webfetch", "Fetch a URL page"),
      deferred_def("memory_search", "Search memories"),
    ],
    Map::from_array([]),
  )
  let ext = build_ok([child])
  observe(ext, gateway_execute_call("bash"))
  observe(ext, gateway_execute_call("webfetch"))
  observe(ext, gateway_execute_call("memory_search"))
  // Direct tools and unknown names never count as deferred usage.
  observe(ext, meta_call("read", Map::from_array([])))
  observe(ext, gateway_execute_call("nope"))
  // Peek via the hook: the hint lists most-recent-first.
  let messages : Array[@posoco.Message] = []
  let injected = (ext as &@posoco.PipelineHook).before_model(messages)
  assert_eq(injected.length(), 1)
  match injected[0] {
    @posoco.Message::UserMessage(content~) =>
      match content {
        [@posoco.Content::Text(text), ..] => {
          assert_true(text.has_prefix("<lazytools-context"))
          assert_true(
            text.contains(
              "Recently used deferred tools: memory_search, webfetch, bash",
            ),
          )
          assert_true(text.contains("skip tool_list"))
        }
        _ => fail("expected text content")
      }
    _ => fail("expected a user message")
  }
}

///|
async test "before_model_replaces_the_hint_in_place_and_honors_the_cap" {
  let defs : Array[@posoco.ToolDef] = []
  for i in 0..<7 {
    defs.push(deferred_def("tool_\{i}", "Filler tool \{i}"))
  }
  let child = recording(defs, Map::from_array([]))
  let ext = build_ok([child])
  for i in 0..<7 {
    observe(ext, gateway_execute_call("tool_\{i}"))
  }
  let messages : Array[@posoco.Message] = []
  let injected = (ext as &@posoco.PipelineHook).before_model(messages)
  match injected[0] {
    @posoco.Message::UserMessage(content~) =>
      match content {
        [@posoco.Content::Text(text), ..] => {
          // Only the five most recent survive, most recent first.
          assert_true(text.contains("tool_6, tool_5, tool_4, tool_3, tool_2"))
          assert_false(text.contains("tool_0"))
        }
        _ => fail("expected text content")
      }
    _ => fail("expected a user message")
  }
  // A re-render with identical content replaces the existing envelope
  // instead of appending a second one.
  let again = (ext as &@posoco.PipelineHook).before_model(injected)
  assert_eq(again.length(), 1)
}

///|
async test "before_model_is_silent_until_the_first_deferred_execution" {
  let child = recording(
    [deferred_def("read", "Read a file")],
    Map::from_array([]),
  )
  let ext = build_ok([child])
  let messages : Array[@posoco.Message] = []
  let untouched = (ext as &@posoco.PipelineHook).before_model(messages)
  assert_eq(untouched.length(), 0)
}

///|
/// ——— manifest port contributions ———

///|
test "manifest_reports_all_four_port_views" {
  let child = recording(
    [deferred_def("read", "Read a file")],
    Map::from_array([]),
  )
  let ext = build_ok([child])
  let manifest = ext.manifest()
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.observers.length(), 1)
  assert_eq(manifest.hooks.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
}
