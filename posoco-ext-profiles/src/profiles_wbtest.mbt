///|
/// ——— Test helpers ———

///|
fn manifest_json(id : String, exts? : Array[String] = []) -> Json {
  Json::object(
    Map::from_array([
      ("id", Json::string(id)),
      ("name", Json::string("MoonBit dev")),
      ("description", Json::string("Working on MoonBit services")),
      ("exts", Json::array(exts.map(fn(ext) { Json::string(ext) }))),
    ]),
  )
}

///|
fn same_manifest(a : ProfileManifest, b : ProfileManifest) -> Bool {
  a.id == b.id &&
  a.name == b.name &&
  a.description == b.description &&
  a.exts == b.exts
}

///|
fn user_msg(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
fn activation_msg(id : String, manual? : String = "") -> @posoco.Message {
  user_msg(activation_header(id) + "\n\n" + manual)
}

///|
fn activate_call(call_id : String, profile~ : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked(call_id),
    name: @posoco.ToolName::unchecked("activate_profile"),
    arguments: Json::object(
      Map::from_array([("profile", Json::string(profile))]),
    ),
  }
}

///|
fn assistant_with_calls(calls : Array[@posoco.ToolCall]) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[],
    tool_calls=calls,
    reasoning=None,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
}

///|
fn tool_result(call_id : String, content : String) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked(call_id),
    tool_name=@posoco.ToolName::unchecked("activate_profile"),
    outcome=@posoco.ToolOutcome::Success(content~, structured=None),
  )
}

///|
/// Minimal extension fake with configurable port arrays.
priv struct FakeProfileExt {
  id : String
  tools : Array[&@posoco.ToolProvider]
  observers : Array[&@posoco.Observer]
  prompts : Array[&@posoco.SystemPromptContributor]
}

///|
impl @posoco.Extension for FakeProfileExt with fn extension_id(
  self : FakeProfileExt,
) -> String {
  self.id
}

///|
impl @posoco.Extension for FakeProfileExt with fn manifest(
  self : FakeProfileExt,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id=self.id,
    tools=self.tools,
    observers=self.observers,
    prompt_contributors=self.prompts,
  )
}

///|
priv struct FixedPrompt {
  text : String
}

///|
impl @posoco.SystemPromptContributor for FixedPrompt with fn system_prompt(
  self : FixedPrompt,
) -> String {
  self.text
}

///|
/// ——— manifest parsing ———

///|
test "parse_accepts_valid_manifest_with_empty_exts" {
  match parse_profile_manifest(manifest_json("moonbit")) {
    Ok(m) => {
      assert_eq(m.id, "moonbit")
      assert_eq(m.name, "MoonBit dev")
      assert_eq(m.description, "Working on MoonBit services")
      assert_eq(m.exts.length(), 0)
    }
    Err(msg) => fail("unexpected parse error: \{msg}")
  }
}

///|
test "parse_roundtrips_through_to_json" {
  match
    parse_profile_manifest(manifest_json("web", exts=["webfetch", "obsidian"])) {
    Ok(m) =>
      match parse_profile_manifest(m.to_json()) {
        Ok(again) => assert_true(same_manifest(again, m))
        Err(msg) => fail("to_json output must re-parse: \{msg}")
      }
    Err(msg) => fail("unexpected parse error: \{msg}")
  }
}

///|
test "parse_rejects_missing_fields" {
  fn without(field : String) -> Json {
    let fields : Array[(String, Json)] = [
      ("id", Json::string("x")),
      ("name", Json::string("n")),
      ("description", Json::string("d")),
      ("exts", Json::array([])),
    ]
    Json::object(Map::from_array(fields.filter(fn(pair) { pair.0 != field })))
  }
  for field in ["id", "name", "description", "exts"] {
    match parse_profile_manifest(without(field)) {
      Err(msg) => assert_true(msg.contains("missing field '\{field}'"))
      Ok(_) => fail("expected missing '\{field}' to be rejected")
    }
  }
}

///|
test "parse_rejects_mistyped_fields" {
  fn overriding(field : String, value : Json) -> Json {
    Json::object(
      Map::from_array([
        ("id", Json::string("x")),
        ("name", Json::string("n")),
        ("description", Json::string("d")),
        ("exts", Json::array([])),
        (field, value),
      ]),
    )
  }
  match parse_profile_manifest(overriding("id", Json::number(3))) {
    Err(msg) => assert_true(msg.contains("'id' must be a string"))
    Ok(_) => fail("expected a non-string id to be rejected")
  }
  match parse_profile_manifest(overriding("name", Json::number(1))) {
    Err(msg) => assert_true(msg.contains("'name' must be a string"))
    Ok(_) => fail("expected a non-string name to be rejected")
  }
  match parse_profile_manifest(overriding("exts", Json::string("a"))) {
    Err(msg) => assert_true(msg.contains("'exts' must be an array"))
    Ok(_) => fail("expected a non-array exts to be rejected")
  }
  match
    parse_profile_manifest(overriding("exts", Json::array([Json::number(7)]))) {
    Err(msg) => assert_true(msg.contains("'exts' must contain only strings"))
    Ok(_) => fail("expected a non-string ext entry to be rejected")
  }
  match parse_profile_manifest(manifest_json("x", exts=[])) {
    Ok(_) => ()
    Err(msg) => fail("empty exts must stay legal: \{msg}")
  }
  match parse_profile_manifest(Json::array([])) {
    Err(msg) => assert_true(msg.contains("must be a JSON object"))
    Ok(_) => fail("expected a non-object manifest to be rejected")
  }
}

///|
test "parse_rejects_empty_and_invalid_ids" {
  for bad in ["all", "a/b", "a\\b", "../escape", ""] {
    match parse_profile_manifest(manifest_json(bad)) {
      Err(_) => ()
      Ok(_) => fail("expected id '\{bad}' to be rejected")
    }
  }
}

///|
test "parse_dedupes_exts_preserving_first_occurrence" {
  match
    parse_profile_manifest(manifest_json("dup", exts=["a", "b", "a", "c", "b"])) {
    Ok(m) => assert_eq(m.exts, ["a", "b", "c"])
    Err(msg) => fail("unexpected parse error: \{msg}")
  }
}

///|
test "to_json_keeps_the_manifest_shape" {
  let m : ProfileManifest = {
    id: "moonbit",
    name: "MoonBit dev",
    description: "d",
    exts: ["a", "b"],
  }
  let text = m.to_json().stringify()
  assert_true(text.contains("\"id\":\"moonbit\""))
  assert_true(text.contains("\"name\":\"MoonBit dev\""))
  assert_true(text.contains("\"description\":\"d\""))
  assert_true(text.contains("\"exts\":[\"a\",\"b\"]"))
}

///|
/// ——— activation header scanning ———

///|
test "scan_collects_ids_in_first_seen_order_without_duplicates" {
  let messages : Array[@posoco.Message] = [
    user_msg("please help"),
    activation_msg("moonbit", manual="MoonBit manual"),
    user_msg("thanks"),
    activation_msg("web", manual="Web manual"),
    activation_msg("moonbit", manual="re-activation attempt"),
  ]
  assert_eq(scan_activated_profiles(messages), ["moonbit", "web"])
}

///|
test "scan_ignores_non_header_and_compact_summary_messages" {
  let messages : Array[@posoco.Message] = [
    // Prose that merely mentions the phrase — not first-line-exact.
    user_msg("The header looks like profile web activated but this is prose."),
    user_msg("profile activated"),
    user_msg("profile web activated!"),
    // A compact summary keeps the meaning but not the frozen header format.
    user_msg(
      "Summary of earlier conversation (profile moonbit was activated earlier).",
    ),
    // Only the real injected header counts.
    activation_msg("web", manual="Web manual"),
  ]
  assert_eq(scan_activated_profiles(messages), ["web"])
  // The exact template always round-trips.
  assert_eq(activation_header("web"), "profile web activated")
}

///|
/// ——— pending activation detection ———

///|
test "pending_after_activated_result_without_header" {
  let messages : Array[@posoco.Message] = [
    user_msg("do things"),
    assistant_with_calls([activate_call("c1", profile="moonbit")]),
    tool_result(
      "c1", "activated: moonbit\n\nManual injected with the next model request.",
    ),
  ]
  assert_eq(find_pending_activations(messages), ["moonbit"])
}

///|
test "unknown_profile_result_never_becomes_pending" {
  let messages : Array[@posoco.Message] = [
    assistant_with_calls([activate_call("c1", profile="nope")]),
    tool_result(
      "c1", "unknown profile: nope\n\nAvailable profiles: moonbit, web",
    ),
  ]
  assert_eq(find_pending_activations(messages), [])
}

///|
test "already_injected_header_is_not_pending_again" {
  let messages : Array[@posoco.Message] = [
    assistant_with_calls([activate_call("c1", profile="moonbit")]),
    tool_result("c1", "activated: moonbit"),
    activation_msg("moonbit", manual="MoonBit manual"),
  ]
  assert_eq(find_pending_activations(messages), [])
}

///|
test "call_without_profile_argument_is_skipped" {
  let malformed : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("c1"),
    name: @posoco.ToolName::unchecked("activate_profile"),
    arguments: Json::object(Map::from_array([])),
  }
  let messages : Array[@posoco.Message] = [
    assistant_with_calls([malformed]),
    tool_result("c1", "activated: something"),
  ]
  assert_eq(find_pending_activations(messages), [])
}

///|
test "error_outcome_and_unexecuted_call_do_not_inject" {
  let failed : @posoco.Message = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("c1"),
    tool_name=@posoco.ToolName::unchecked("activate_profile"),
    outcome=@posoco.ToolOutcome::ToolReportedError(
      content="activated: moonbit",
      structured=None,
    ),
  )
  let messages : Array[@posoco.Message] = [
    assistant_with_calls([activate_call("c1", profile="moonbit")]),
    failed,
  ]
  assert_eq(find_pending_activations(messages), [])
  // No ToolMessage at all (call never executed) — also no injection.
  let unexecuted : Array[@posoco.Message] = [
    assistant_with_calls([activate_call("c2", profile="moonbit")]),
  ]
  assert_eq(find_pending_activations(unexecuted), [])
}

///|
test "pending_results_are_ordered_and_deduplicated" {
  let messages : Array[@posoco.Message] = [
    assistant_with_calls([
      activate_call("c1", profile="web"),
      activate_call("c2", profile="moonbit"),
      activate_call("c3", profile="web"),
    ]),
    tool_result("c1", "activated: web"),
    tool_result("c2", "activated: moonbit"),
    tool_result("c3", "activated: web"),
  ]
  assert_eq(find_pending_activations(messages), ["web", "moonbit"])
}

///|
/// ——— deep deferred views ———

///|
test "deep_defer_strips_tools_and_prompt_sections_keeps_other_ports" {
  let ext : &@posoco.Extension = FakeProfileExt::{
    id: "fake_nmem",
    tools: [@posoco.RecordingToolProvider([], Map::from_array([]))],
    observers: [@posoco.RecordingObserver()],
    prompts: [FixedPrompt::{ text: "Memory manual.", }],
  }
  let resident : &@posoco.Extension = FakeProfileExt::{
    id: "fake_identity",
    tools: [],
    observers: [],
    prompts: [],
  }
  let (prompts, views) = deep_defer_extensions(exts=[ext, resident])
  // The stripped prompt text lands in the map, keyed by extension id.
  assert_eq(prompts.get("fake_nmem"), Some("Memory manual."))
  assert_false(prompts.contains("fake_identity"))
  assert_eq(views.length(), 2)
  let view = views[0]
  assert_eq(view.extension_id(), "fake_nmem")
  let m = view.manifest()
  assert_eq(m.tools.length(), 0)
  assert_eq(m.prompt_contributors.length(), 0)
  // Everything else is preserved for composition attribution.
  assert_eq(m.observers.length(), 1)
  // A tool-free, prompt-free extension passes through untouched.
  assert_eq(views[1].extension_id(), "fake_identity")
  assert_eq(views[1].manifest().tools.length(), 0)
  assert_eq(views[1].manifest().prompt_contributors.length(), 0)
}

///|
test "deep_defer_joins_contributors_and_skips_empty_text" {
  let ext : &@posoco.Extension = FakeProfileExt::{
    id: "fake_multi",
    tools: [],
    observers: [],
    prompts: [
      FixedPrompt::{ text: "Section A", },
      FixedPrompt::{ text: "", },
      FixedPrompt::{ text: "Section B", },
    ],
  }
  let (prompts, views) = deep_defer_extensions(exts=[ext])
  assert_eq(prompts.get("fake_multi"), Some("Section A\nSection B"))
  assert_eq(views.length(), 1)
  assert_eq(views[0].manifest().prompt_contributors.length(), 0)
}

///|
test "deep_defer_tools_only_extension_gets_view_but_no_prompt_entry" {
  let ext : &@posoco.Extension = FakeProfileExt::{
    id: "fake_tools_only",
    tools: [@posoco.RecordingToolProvider([], Map::from_array([]))],
    observers: [],
    prompts: [],
  }
  let (prompts, views) = deep_defer_extensions(exts=[ext])
  assert_false(prompts.contains("fake_tools_only"))
  assert_eq(views.length(), 1)
  assert_eq(views[0].extension_id(), "fake_tools_only")
  assert_eq(views[0].manifest().tools.length(), 0)
  assert_eq(views[0].manifest().prompt_contributors.length(), 0)
}

///|
/// ——— ProfileStore seam ———

///|
priv struct InMemoryProfileStore {
  mut entries : Array[(String, ProfileManifest)]
}

///|
fn InMemoryProfileStore::InMemoryProfileStore() -> InMemoryProfileStore {
  { entries: [], }
}

///|
impl ProfileStore for InMemoryProfileStore with fn read_all(self) {
  Ok(
    self.entries.map(fn(entry) {
      let (level, manifest) = entry
      (level, manifest.to_json().stringify())
    }),
  )
}

///|
impl ProfileStore for InMemoryProfileStore with fn write(self, level, manifest) {
  // One manifest per (level, id): file semantics — a rewrite replaces.
  let next : Array[(String, ProfileManifest)] = []
  let mut replaced = false
  for entry in self.entries {
    let (lvl, m) = entry
    if lvl == level && m.id == manifest.id {
      next.push((level, manifest))
      replaced = true
    } else {
      next.push(entry)
    }
  }
  if !replaced {
    next.push((level, manifest))
  }
  self.entries = next
  Ok(())
}

///|
extend InMemoryProfileStore with ProfileStore::{read_all, write}

///|
test "store_roundtrips_manifests_across_levels" {
  let store = InMemoryProfileStore::InMemoryProfileStore()
  let user_manifest : ProfileManifest = {
    id: "moonbit",
    name: "MoonBit dev",
    description: "d",
    exts: ["a"],
  }
  let project_manifest : ProfileManifest = {
    id: "moonbit",
    name: "Repo MoonBit",
    description: "d2",
    exts: [],
  }
  match store.write("user", user_manifest) {
    Ok(_) => ()
    Err(msg) => fail("unexpected write error: \{msg}")
  }
  match store.write("project", project_manifest) {
    Ok(_) => ()
    Err(msg) => fail("unexpected write error: \{msg}")
  }
  let all = match store.read_all() {
    Ok(pairs) => pairs
    Err(msg) => fail("unexpected read error: \{msg}")
  }
  assert_eq(all.length(), 2)
  let mut saw_user = false
  let mut saw_project = false
  for pair in all {
    let (level, raw) = pair
    let value = @json.parse(raw) catch {
      _ => fail("stored manifest must be valid JSON")
    }
    match parse_profile_manifest(value) {
      Ok(m) =>
        match level {
          "user" => {
            saw_user = true
            assert_true(same_manifest(m, user_manifest))
          }
          "project" => {
            saw_project = true
            assert_true(same_manifest(m, project_manifest))
          }
          _ => fail("unexpected level: \{level}")
        }
      Err(msg) => fail("stored manifest must re-parse: \{msg}")
    }
  }
  assert_true(saw_user && saw_project)
}

///|
test "store_write_replaces_same_level_and_id" {
  let store = InMemoryProfileStore::InMemoryProfileStore()
  let first : ProfileManifest = {
    id: "web",
    name: "Web",
    description: "d",
    exts: [],
  }
  let second : ProfileManifest = {
    id: "web",
    name: "Web v2",
    description: "d2",
    exts: ["webfetch"],
  }
  let _ = store.write("user", first)
  let _ = store.write("user", second)
  match store.read_all() {
    Ok(pairs) => {
      assert_eq(pairs.length(), 1)
      match pairs[0] {
        (level, raw) => {
          assert_eq(level, "user")
          match parse_profile_manifest(@json.parse(raw)) {
            Ok(m) => assert_true(same_manifest(m, second))
            Err(msg) => fail("replaced manifest must re-parse: \{msg}")
          }
        }
      }
    }
    Err(msg) => fail("unexpected read error: \{msg}")
  }
}
