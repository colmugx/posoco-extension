///|
/// White-box tests. The subprocess boundary is faked with a scripted CliIo
/// that records every argv so tests can assert both the dispatch and the
/// exact CLI invocation shape (vault selector first, key=value tokens).

///|
priv struct FakeCli {
  calls : Array[String]
  results : Array[CliResult]
  mut next : Int
}

///|
fn FakeCli::new(results : Array[CliResult]) -> FakeCli {
  { calls: [], results, next: 0, }
}

///|
impl CliIo for FakeCli with fn run(
  self : FakeCli,
  cli_path : String,
  args : Array[String],
) -> CliResult raise @posoco.RuntimeError {
  self.calls.push("\{cli_path} \{args.join(" ")}")
  if self.next >= self.results.length() {
    return { exit_code: 0, output: "", }
  }
  let r = self.results[self.next]
  self.next += 1
  r
}

///|
fn ok_result(output : String) -> CliResult {
  { exit_code: 0, output, }
}

///|
/// `obsidian file` metadata body for freshness stamps (ms epochs).
fn file_meta(size : Int, modified_ms : String) -> String {
  "path\tnotes/x.md\nname\tx\nextension\tmd\nsize\t\{size}\ncreated\t1788014579751\nmodified\t\{modified_ms}\n"
}

///|
const STAMP_A = "1788014584252"

///|
fn test_config() -> ObsidianConfig {
  ObsidianConfig::ObsidianConfig(
    cli_path="obsidian-fake",
    vault=Some("Test Vault"),
    read_paths=["notes"],
    read_only=false,
    write_paths=["notes"],
  )
}

///|
fn make_tools() -> ObsidianTools {
  ObsidianTools::new(config=test_config())
}

///|
fn call(name~ : String, pairs~ : Array[(String, Json)]) -> @posoco.ToolCall {
  let map : Map[String, Json] = Map::from_array([])
  for kv in pairs {
    map[kv.0] = kv.1
  }
  {
    call_id: @posoco.CallId::unchecked("t"),
    name: @posoco.ToolName::unchecked(name),
    arguments: Json::object(map),
  }
}

///|
fn s(key : String, value : String) -> (String, Json) {
  (key, Json::string(value))
}

///|
fn b(key : String, value : Bool) -> (String, Json) {
  (key, Json::boolean(value))
}

///|
fn i(key : String, value : Int) -> (String, Json) {
  (key, Json::number(value.to_double()))
}

///|
/// (is_error, content, structured summary) of an outcome.
fn outcome_parts(outcome : @posoco.ToolOutcome) -> (Bool, String, String?) {
  match outcome {
    @posoco.ToolOutcome::Success(content~, structured~) =>
      (false, content, summary_of(structured))
    @posoco.ToolOutcome::ToolReportedError(content~, structured=_) =>
      (true, content, None)
    _ => (true, "unexpected outcome variant", None)
  }
}

///|
fn summary_of(structured : Json?) -> String? {
  match structured {
    Some(Json::Object(map)) =>
      match map.get("summary") {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
    _ => None
  }
}

///|
async fn run(
  tools : ObsidianTools,
  fake : FakeCli,
  name~ : String,
  pairs~ : Array[(String, Json)],
) -> @posoco.ToolOutcome {
  tools.execute_impl(fake, name, call(name~, pairs~))
}

///|
async test "read_happy_path_records_freshness" {
  let tools = make_tools()
  let fake = FakeCli::new([
    ok_result("# Top\n\nbody line\n"),
    ok_result(file_meta(18, STAMP_A)),
  ])
  let outcome = run(tools, fake, name="obsidian_read_note", pairs=[
    s("path", "notes/x.md"),
  ])
  let (is_err, content, summary) = outcome_parts(outcome)
  assert_false(is_err)
  inspect(content, content="L1: # Top\nL2: \nL3: body line\n")
  debug_inspect(
    summary,
    content=(
      #|Some("read notes/x.md L1-L3")
    ),
  )
  // read goes first, then the freshness stat
  assert_true(fake.calls[0].contains("read path=notes/x.md"))
  assert_true(fake.calls[1].contains("file path=notes/x.md"))
  assert_true(fake.calls[0].has_prefix("obsidian-fake vault=Test Vault "))
}

///|
async test "read_pagination_footer" {
  let tools = make_tools()
  let fake = FakeCli::new([
    ok_result("a\nb\nc\nd\ne\n"),
    ok_result(file_meta(10, STAMP_A)),
  ])
  let outcome = run(tools, fake, name="obsidian_read_note", pairs=[
    s("path", "notes/x.md"),
    i("offset", 2),
    i("limit", 2),
  ])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_false(is_err)
  inspect(
    content,
    content="L2: b\nL3: c\n…[2 more lines; re-read with offset=4]",
  )
}

///|
async test "read_refuses_reserved_and_escaping_paths" {
  let tools = make_tools()
  for path in [".obsidian/app.json", "../escape.md", "/abs/path.md"] {
    let fake = FakeCli::new([])
    let outcome = run(tools, fake, name="obsidian_read_note", pairs=[
      s("path", path),
    ])
    let (is_err, content, _) = outcome_parts(outcome)
    assert_true(is_err)
    assert_true(content.contains("path refused"))
    assert_eq(fake.calls.length(), 0)
  }
}

///|
async test "read_write_path_refused_outside_allowlist" {
  let tools = make_tools()
  let fake = FakeCli::new([])
  let outcome = run(tools, fake, name="obsidian_read_note", pairs=[
    s("path", "other/y.md"),
  ])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_true(is_err)
  assert_true(content.contains("outside read_paths"))
}

///|
async test "search_parses_json_and_counts" {
  let tools = make_tools()
  let body = "[{\"file\":\"notes/x.md\",\"matches\":[{\"line\":3,\"text\":\"needle here\"}]},{\"file\":\"notes/y.md\",\"matches\":[{\"line\":7,\"text\":\"needle too\"}]}]"
  let fake = FakeCli::new([ok_result(body)])
  let outcome = run(tools, fake, name="obsidian_search", pairs=[
    s("query", "needle"),
  ])
  let (is_err, content, summary) = outcome_parts(outcome)
  assert_false(is_err)
  inspect(
    content,
    content="notes/x.md:3: needle here\nnotes/y.md:7: needle too\n",
  )
  debug_inspect(
    summary,
    content=(
      #|Some("2 matches")
    ),
  )
  assert_true(fake.calls[0].contains("search:context query=needle format=json"))
}

///|
async test "search_case_flag_and_no_matches" {
  let tools = makeToolsWithNoMatches()
  let outcome = run(tools.0, tools.1, name="obsidian_search", pairs=[
    s("query", "Needle"),
    b("case_sensitive", true),
  ])
  let (is_err, content, summary) = outcome_parts(outcome)
  assert_false(is_err)
  inspect(content, content="No matches.")
  debug_inspect(
    summary,
    content=(
      #|Some("0 matches")
    ),
  )
  assert_true(tools.1.calls[0].contains(" case"))
}

///|
fn makeToolsWithNoMatches() -> (ObsidianTools, FakeCli) {
  let fake = FakeCli::new([ok_result("No matches found.")])
  (make_tools(), fake)
}

///|
async test "cli_error_with_exit_zero_is_tool_reported_error" {
  let tools = make_tools()
  let fake = FakeCli::new([
    ok_result("Error: File \"notes/gone.md\" not found."),
  ])
  let outcome = run(tools, fake, name="obsidian_read_note", pairs=[
    s("path", "notes/gone.md"),
  ])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_true(is_err)
  inspect(content, content="Error: File \"notes/gone.md\" not found.")
}

///|
async test "outline_and_frontmatter_pass_through" {
  let tools = make_tools()
  let fake = FakeCli::new([
    ok_result("[{\"level\":1,\"heading\":\"Top\",\"line\":1}]"),
    ok_result(file_meta(30, STAMP_A)),
  ])
  let outcome = run(tools, fake, name="obsidian_outline", pairs=[
    s("path", "notes/x.md"),
  ])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_false(is_err)
  assert_true(content.contains("\"heading\":\"Top\""))
  let tools2 = make_tools()
  let fake2 = FakeCli::new([ok_result("{\n  \"status\": \"draft\"\n}")])
  let outcome2 = run(tools2, fake2, name="obsidian_get_frontmatter", pairs=[
    s("path", "notes/x.md"),
  ])
  let (is_err2, content2, _) = outcome_parts(outcome2)
  assert_false(is_err2)
  assert_true(content2.contains("draft"))
}

///|
async test "backlinks_kind_backlinks_requires_path" {
  let tools = make_tools()
  let fake = FakeCli::new([])
  let outcome = run(tools, fake, name="obsidian_backlinks", pairs=[
    s("kind", "backlinks"),
  ])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_true(is_err)
  inspect(content, content="path is required for kind=backlinks")
  let fake2 = FakeCli::new([
    ok_result("[{\"file\":\"notes/other.md\",\"count\":\"2\"}]"),
  ])
  let outcome2 = run(tools, fake2, name="obsidian_backlinks", pairs=[
    s("kind", "backlinks"),
    s("path", "notes/x.md"),
  ])
  let (is_err2, content2, _) = outcome_parts(outcome2)
  assert_false(is_err2)
  assert_true(content2.contains("notes/other.md"))
  assert_true(
    fake2.calls[0].contains("backlinks path=notes/x.md format=json counts"),
  )
}

///|
async test "create_passes_flags_and_escapes_newlines" {
  let tools = make_tools()
  let fake = FakeCli::new([ok_result("Created: notes/x.md\n")])
  let outcome = run(tools, fake, name="obsidian_create_note", pairs=[
    s("path", "notes/x.md"),
    s("content", "line1\nline2"),
  ])
  let (is_err, _, _) = outcome_parts(outcome)
  assert_false(is_err)
  assert_true(fake.calls[0].contains("content=line1\\nline2"))
  assert_false(fake.calls[0].contains("overwrite"))
  let fake2 = FakeCli::new([ok_result("Created: notes/x.md\n")])
  let outcome2 = run(tools, fake2, name="obsidian_create_note", pairs=[
    s("path", "notes/x.md"),
    s("content", "x"),
    b("overwrite", true),
  ])
  let (is_err2, _, _) = outcome_parts(outcome2)
  assert_false(is_err2)
  assert_true(fake2.calls[0].contains(" overwrite"))
}

///|
async test "create_refused_in_read_only_mode" {
  let ro_tools = ObsidianTools::new(
    config=ObsidianConfig::ObsidianConfig(cli_path="obsidian-fake", vault=None),
  )
  // read-only default: write tools unlisted AND execute refuses
  let fake = FakeCli::new([])
  let outcome = run(ro_tools, fake, name="obsidian_create_note", pairs=[
    s("path", "notes/x.md"),
    s("content", "x"),
  ])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_true(is_err)
  assert_true(content.contains("outside write_paths"))
  assert_eq(fake.calls.length(), 0)
  // read-only config does not even list write tools
  assert_eq(ro_tools.list_tools().length(), 6)
  // non-read-only with empty write_paths = whole vault writable
  let rw_tools = ObsidianTools::new(
    config=ObsidianConfig::ObsidianConfig(
      cli_path="obsidian-fake",
      read_only=false,
    ),
  )
  assert_eq(rw_tools.list_tools().length(), 9)
  let rw_fake = FakeCli::new([ok_result("Created: x.md\n")])
  let rw_outcome = run(rw_tools, rw_fake, name="obsidian_create_note", pairs=[
    s("path", "anywhere/x.md"),
    s("content", "x"),
  ])
  let (rw_err, _, _) = outcome_parts(rw_outcome)
  assert_false(rw_err)
}

///|
async test "delete_requires_verbatim_confirm_and_passes_permanent" {
  let tools = make_tools()
  let fake = FakeCli::new([])
  let outcome = run(tools, fake, name="obsidian_delete_note", pairs=[
    s("path", "notes/x.md"),
    s("confirm_path", "notes/y.md"),
  ])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_true(is_err)
  assert_true(content.contains("confirm_path must equal path exactly"))
  let fake2 = FakeCli::new([ok_result("Moved to trash: notes/x.md\n")])
  let outcome2 = run(tools, fake2, name="obsidian_delete_note", pairs=[
    s("path", "notes/x.md"),
    s("confirm_path", "notes/x.md"),
  ])
  let (is_err2, _, _) = outcome_parts(outcome2)
  assert_false(is_err2)
  assert_false(fake2.calls[0].contains("permanent"))
  let fake3 = FakeCli::new([ok_result("Deleted: notes/x.md\n")])
  let outcome3 = run(tools, fake3, name="obsidian_delete_note", pairs=[
    s("path", "notes/x.md"),
    s("confirm_path", "notes/x.md"),
    b("permanent", true),
  ])
  let (is_err3, _, _) = outcome_parts(outcome3)
  assert_false(is_err3)
  assert_true(fake3.calls[0].contains(" permanent"))
}

///|
async test "patch_replace_never_read_is_refused" {
  let tools = make_tools()
  let fake = FakeCli::new([ok_result(file_meta(30, STAMP_A))])
  let outcome = run(tools, fake, name="obsidian_patch_note", pairs=[
    s("path", "notes/x.md"),
    s("operation", "replace"),
    s("target_type", "heading"),
    s("target", "Alpha"),
    s("content", "new body"),
  ])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_true(is_err)
  assert_true(content.contains("has not been read"))
}

///|
async test "patch_replace_splices_section_and_rewrites" {
  let tools = make_tools()
  // seed a fresh read (read + stat)
  let warm = FakeCli::new([
    ok_result(
      "---\nstatus: draft\n---\n# Top\n\n## Alpha\n\nold body\n\n## Beta\n\ntail\n",
    ),
    ok_result(file_meta(60, STAMP_A)),
  ])
  let _ = run(tools, warm, name="obsidian_read_note", pairs=[
    s("path", "notes/x.md"),
  ])
  // patch: stat (fresh) -> outline -> read -> create overwrite
  let outline = "[{\"level\":2,\"heading\":\"Alpha\",\"line\":6},{\"level\":2,\"heading\":\"Beta\",\"line\":10}]"
  let fake = FakeCli::new([
    ok_result(file_meta(60, STAMP_A)),
    ok_result(outline),
    ok_result(
      "---\nstatus: draft\n---\n# Top\n\n## Alpha\n\nold body\n\n## Beta\n\ntail\n",
    ),
    ok_result("Created: notes/x.md\n"),
  ])
  let outcome = run(tools, fake, name="obsidian_patch_note", pairs=[
    s("path", "notes/x.md"),
    s("operation", "replace"),
    s("target_type", "heading"),
    s("target", "Alpha"),
    s("content", "new body\nmore"),
  ])
  let (is_err, _, summary) = outcome_parts(outcome)
  assert_false(is_err)
  debug_inspect(
    summary,
    content=(
      #|Some("replace section \"Alpha\" in notes/x.md")
    ),
  )
  // the rewrite must be a create with overwrite
  assert_true(fake.calls[3].contains("create path=notes/x.md overwrite"))
  // spliced content keeps the heading, replaces only the section body
  assert_true(fake.calls[3].contains("## Alpha\\nnew body\\nmore\\n## Beta"))
}

///|
async test "patch_replace_ambiguous_and_missing_headings" {
  let tools = make_tools()
  let warm = FakeCli::new([
    ok_result("# Top\n"),
    ok_result(file_meta(6, STAMP_A)),
  ])
  let _ = run(tools, warm, name="obsidian_read_note", pairs=[
    s("path", "notes/x.md"),
  ])
  let dup = "[{\"level\":2,\"heading\":\"Alpha\",\"line\":3},{\"level\":2,\"heading\":\"Alpha\",\"line\":7}]"
  let fake = FakeCli::new([ok_result(file_meta(6, STAMP_A)), ok_result(dup)])
  let outcome = run(tools, fake, name="obsidian_patch_note", pairs=[
    s("path", "notes/x.md"),
    s("operation", "replace"),
    s("target_type", "heading"),
    s("target", "Alpha"),
    s("content", "x"),
  ])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_true(is_err)
  assert_true(content.contains("ambiguous heading"))
  let fake2 = FakeCli::new([ok_result(file_meta(6, STAMP_A)), ok_result("[]")])
  let outcome2 = run(tools, fake2, name="obsidian_patch_note", pairs=[
    s("path", "notes/x.md"),
    s("operation", "delete"),
    s("target_type", "heading"),
    s("target", "Missing"),
  ])
  let (is_err2, content2, _) = outcome_parts(outcome2)
  assert_true(is_err2)
  assert_true(content2.contains("available headings: (none)"))
}

///|
async test "patch_frontmatter_and_append" {
  let tools = make_tools()
  let fake = FakeCli::new([ok_result("Set status: draft\n")])
  let outcome = run(tools, fake, name="obsidian_patch_note", pairs=[
    s("path", "notes/x.md"),
    s("operation", "replace"),
    s("target_type", "frontmatter"),
    s("target", "status"),
    s("content", "draft"),
  ])
  let (is_err, _, _) = outcome_parts(outcome)
  assert_false(is_err)
  assert_true(fake.calls[0].contains("property:set name=status value=draft"))
  let fake2 = FakeCli::new([ok_result("Removed status\n")])
  let outcome2 = run(tools, fake2, name="obsidian_patch_note", pairs=[
    s("path", "notes/x.md"),
    s("operation", "delete"),
    s("target_type", "frontmatter"),
    s("target", "status"),
  ])
  let (is_err2, _, _) = outcome_parts(outcome2)
  assert_false(is_err2)
  assert_true(fake2.calls[0].contains("property:remove"))
  let fake3 = FakeCli::new([ok_result("Prepended to: notes/x.md\n")])
  let outcome3 = run(tools, fake3, name="obsidian_patch_note", pairs=[
    s("path", "notes/x.md"),
    s("operation", "prepend"),
    s("target_type", "heading"),
    s("target", "-"),
    s("content", "FIRST"),
  ])
  let (is_err3, _, _) = outcome_parts(outcome3)
  assert_false(is_err3)
  assert_true(fake3.calls[0].contains("prepend path=notes/x.md content=FIRST"))
}

///|
async test "list_notes_filters_by_read_allowlist" {
  let tools = make_tools()
  let fake = FakeCli::new([
    ok_result("notes/a.md\nother/b.md\nnotes/sub/c.md\n"),
  ])
  let outcome = run(tools, fake, name="obsidian_list_notes", pairs=[])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_false(is_err)
  inspect(content, content="notes/a.md\nnotes/sub/c.md\n")
}

///|
async test "move_passes_to_and_updates_ledger" {
  let tools = make_tools()
  let warm = FakeCli::new([ok_result("# x\n"), ok_result(file_meta(4, STAMP_A))])
  let _ = run(tools, warm, name="obsidian_read_note", pairs=[
    s("path", "notes/x.md"),
  ])
  let fake = FakeCli::new([ok_result("Moved: notes/x.md -> notes/y.md\n")])
  let outcome = run(tools, fake, name="obsidian_move_note", pairs=[
    s("path", "notes/x.md"),
    s("new_path", "notes/y.md"),
  ])
  let (is_err, _, summary) = outcome_parts(outcome)
  assert_false(is_err)
  debug_inspect(
    summary,
    content=(
      #|Some("moved notes/x.md -> notes/y.md")
    ),
  )
  assert_true(fake.calls[0].contains("move path=notes/x.md to=notes/y.md"))
}

///|
async test "unknown_tool_is_reported_error" {
  let tools = make_tools()
  let fake = FakeCli::new([])
  let outcome = run(tools, fake, name="obsidian_nope", pairs=[])
  let (is_err, content, _) = outcome_parts(outcome)
  assert_true(is_err)
  inspect(content, content="unknown tool: obsidian_nope")
}

///|
/// Recording UiPort fake: captures Confirm prompts, answers with a script.
priv struct RecordingUi {
  prompts : Array[String]
  answer : @posoco.UiResponse
}

///|
impl @posoco.UiPort for RecordingUi with fn ui_descriptor(_self : RecordingUi) -> @posoco.UiDescriptor {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for RecordingUi with fn render(
  _self : RecordingUi,
  _intent : @posoco.UiRender,
) -> Unit {

}

///|
impl @posoco.UiPort for RecordingUi with fn request(
  self : RecordingUi,
  req : @posoco.UiRequest,
) -> @posoco.UiResponse {
  match req {
    @posoco.UiRequest::Confirm(prompt~) => self.prompts.push(prompt)
    _ => ()
  }
  self.answer
}

///|
async test "before_tool_consent_gate" {
  let tools = make_tools()
  let delete_call = call(name="obsidian_delete_note", pairs=[
    s("path", "notes/x.md"),
    s("confirm_path", "notes/x.md"),
    b("permanent", true),
  ])
  // no UI composed: destructive write is rejected, never silently passed
  let decision = @posoco.PipelineHook::before_tool(tools, delete_call)
  assert_true(decision is @posoco.ToolDecision::Reject(_))
  // ordinary reads need no consent even without UI
  let read_call = call(name="obsidian_read_note", pairs=[
    s("path", "notes/x.md"),
  ])
  assert_true(
    @posoco.PipelineHook::before_tool(tools, read_call)
    is @posoco.ToolDecision::Approve(_),
  )
  // with a consenting UI: ApproveAfterConsent and the prompt names the note
  let ui_yes = RecordingUi::{ prompts: [], answer: @posoco.UiResponse::Yes, }
  tools.ui = Some(ui_yes as &@posoco.UiPort)
  match @posoco.PipelineHook::before_tool(tools, delete_call) {
    @posoco.ToolDecision::ApproveAfterConsent(call=_, consent_scope~) =>
      inspect(consent_scope, content="obsidian_write")
    other => fail("expected ApproveAfterConsent, got \{other.to_string()}")
  }
  inspect(
    ui_yes.prompts[0],
    content="Permanently delete vault note \"notes/x.md\" (skips trash)?",
  )
  // user says no: rejected
  let ui_no = RecordingUi::{ prompts: [], answer: @posoco.UiResponse::No, }
  tools.ui = Some(ui_no as &@posoco.UiPort)
  assert_true(
    @posoco.PipelineHook::before_tool(tools, delete_call)
    is @posoco.ToolDecision::Reject(_),
  )
  // trash-only delete needs no consent
  let trash_call = call(name="obsidian_delete_note", pairs=[
    s("path", "notes/x.md"),
    s("confirm_path", "notes/x.md"),
  ])
  assert_true(
    @posoco.PipelineHook::before_tool(tools, trash_call)
    is @posoco.ToolDecision::Approve(_),
  )
}

///|
test "tool_catalog_respects_config" {
  let tools = make_tools()
  // 6 reads + create + patch + move = 9 (delete gated off)
  assert_eq(tools.list_tools().length(), 9)
  let del_tools = ObsidianTools::new(
    config=ObsidianConfig::ObsidianConfig(
      cli_path="obsidian-fake",
      read_only=false,
      write_paths=["notes"],
      allow_delete=true,
    ),
  )
  assert_eq(del_tools.list_tools().length(), 10)
  for t in tools.list_tools() {
    if is_write_tool(t.name.to_string()) {
      assert_true(t.policy is @posoco.ExecutionPolicy::Exclusive)
    } else {
      assert_true(t.policy is @posoco.ExecutionPolicy::Parallel)
    }
  }
}

///|
fn is_write_tool(name : String) -> Bool {
  match name {
    "obsidian_create_note"
    | "obsidian_patch_note"
    | "obsidian_move_note"
    | "obsidian_delete_note" => true
    _ => false
  }
}

///|
test "system_prompt_is_byte_stable" {
  let a = make_tools().system_prompt()
  let b = make_tools().system_prompt()
  assert_eq(a, b)
  assert_true(a.contains("obsidian_outline"))
}
