///|
fn tool_call(name : String, arguments : Json) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("c1"),
    name: @posoco.ToolName::unchecked(name),
    arguments,
  }
}

///|
/// Extension over echo transport with a scripted runner, an optional
/// space-scoped config, and the delete-tool toggle.
fn tool_ext(
  runner? : FakeRunner = FakeRunner::FakeRunner(),
  expose_delete_tool? : Bool = false,
  space? : String? = None,
) -> NowledgeMem {
  let ext = NowledgeMem::new(
    source_app="posoco",
    transport=EchoNmemTransport::EchoNmemTransport(),
    runner~,
    expose_delete_tool~,
  )
  ext.config = Some(lane_config(space~))
  ext
}

///|
/// Outcome text for Success/ToolReportedError assertions; "" for the rest.
fn outcome_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => content
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => content
    _ => ""
  }
}

///|
test "list_tools: nine tools by default, memory_delete only when exposed" {
  let default = @posoco.ToolProvider::list_tools(tool_ext())
  inspect(default.length(), content="9")
  let names : Array[String] = []
  for def in default {
    names.push(def.name.to_string())
  }
  for
    expected in [
      "nmem_status", "read_context_bundle", "read_working_memory", "memory_search",
      "memory_add", "memory_update", "thread_search", "thread_show", "thread_create",
    ] {
    assert_true(names.contains(expected))
  }
  assert_false(names.contains("memory_delete"))
  let exposed = @posoco.ToolProvider::list_tools(
    tool_ext(expose_delete_tool=true),
  )
  inspect(exposed.length(), content="10")
  let exposed_names : Array[String] = []
  for def in exposed {
    exposed_names.push(def.name.to_string())
  }
  assert_true(exposed_names.contains("memory_delete"))
  // Placeholder owner and safe default policy are overwritten by the catalog.
  inspect(exposed[0].owner.to_string() == "placeholder", content="true")
  inspect(
    exposed[0].policy is @posoco.ExecutionPolicy::Parallel,
    content="true",
  )
}

///|
async test "memory_search: assembles the server-side search argv and returns stdout" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:search", { exit: 0, stdout: "{\"memories\":[]}", stderr: "" }),
    ]),
  )
  let ext = tool_ext(runner~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "memory_search",
    tool_call(
      "memory_search",
      j(
        "{\"query\":\"auth flow\",\"mode\":\"deep\",\"limit\":3,\"importance_min\":0.5,\"labels\":[\"backend\"]}",
      ),
    ),
  )
  guard outcome is @posoco.ToolOutcome::Success(..) else {
    fail("expected success")
  }
  inspect(outcome_text(outcome), content="{\"memories\":[]}")
  debug_inspect(
    runner.calls[0],
    content=(
      #|[
      #|  "--json",
      #|  "m",
      #|  "search",
      #|  "auth flow",
      #|  "--mode",
      #|  "deep",
      #|  "-n",
      #|  "3",
      #|  "--importance",
      #|  "0.5",
      #|  "-l",
      #|  "backend",
      #|]
    ),
  )
}

///|
async test "memory_search: ambient space scopes m and t commands" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:search", { exit: 0, stdout: "{}", stderr: "" }),
    ]),
  )
  let ext = tool_ext(runner~, space=Some("team"))
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "memory_search",
    tool_call("memory_search", j("{\"query\":\"x\"}")),
  )
  guard outcome is @posoco.ToolOutcome::Success(..) else {
    fail("expected success")
  }
  assert_true(runner.calls[0].contains("--space"))
  assert_true(runner.calls[0].contains("team"))
}

///|
async test "nmem_status: success returns stdout, missing CLI reports unavailable" {
  let ok_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("status", { exit: 0, stdout: "{\"mode\":\"local\"}", stderr: "" }),
    ]),
  )
  let ok_ext = tool_ext(runner=ok_runner)
  let ok = @posoco.ToolProvider::execute(
    ok_ext,
    "nmem_status",
    tool_call("nmem_status", Json::object(Map::from_array([]))),
  )
  guard ok is @posoco.ToolOutcome::Success(..) else { fail("expected success") }
  inspect(outcome_text(ok), content="{\"mode\":\"local\"}")
  // exit -1 with empty output — the "nmem is missing" shape.
  let missing_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("status", { exit: NMEM_CLI_ABORT_EXIT, stdout: "", stderr: "" }),
    ]),
  )
  let missing_ext = tool_ext(runner=missing_runner)
  let missing = @posoco.ToolProvider::execute(
    missing_ext,
    "nmem_status",
    tool_call("nmem_status", Json::object(Map::from_array([]))),
  )
  guard missing is @posoco.ToolOutcome::ToolReportedError(..) else {
    fail("expected a reported error")
  }
  assert_true(outcome_text(missing).contains("nmem unavailable"))
}

///|
async test "memory_add: queues through MemoryPort, drain maps metadata to flags" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:add", { exit: 0, stdout: "{\"id\":\"mem_5\"}", stderr: "" }),
    ]),
  )
  let ext = tool_ext(runner~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "memory_add",
    tool_call(
      "memory_add",
      j(
        "{\"content\":\"note\",\"title\":\"N\",\"unit_type\":\"fact\",\"importance\":0.8,\"labels\":[\"a\"]}",
      ),
    ),
  )
  guard outcome is @posoco.ToolOutcome::Success(content~, structured~) else {
    fail("expected success")
  }
  inspect(content, content="queued as pending:1; will sync to Nowledge Mem")
  guard structured is Some(payload) else { fail("expected structured") }
  inspect(
    json_field(payload, "pending_id") is Some(Json::String("pending:1")),
    content="true",
  )
  // The write went to the queue, not the CLI.
  inspect(runner.calls.length(), content="0")
  inspect(ext.mem.queue.length(), content="1")
  ext.drain_memory_ops()
  debug_inspect(
    runner.calls[0],
    content=(
      #|[
      #|  "--json",
      #|  "m",
      #|  "add",
      #|  "note",
      #|  "-t",
      #|  "N",
      #|  "--unit-type",
      #|  "fact",
      #|  "-i",
      #|  "0.8",
      #|  "-l",
      #|  "a",
      #|]
    ),
  )
  inspect(ext.mem.index[0].id, content="mem_5")
}

///|
async test "memory_add: invalid unit_type is a reported error naming the field" {
  let ext = tool_ext()
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "memory_add",
    tool_call("memory_add", j("{\"content\":\"x\",\"unit_type\":\"vibe\"}")),
  )
  guard outcome is @posoco.ToolOutcome::ToolReportedError(..) else {
    fail("expected a reported error")
  }
  assert_true(outcome_text(outcome).contains("unit_type"))
  inspect(ext.mem.queue.length(), content="0")
}

///|
async test "memory_search: missing query is a reported error naming the field" {
  let ext = tool_ext()
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "memory_search",
    tool_call("memory_search", Json::object(Map::from_array([]))),
  )
  guard outcome is @posoco.ToolOutcome::ToolReportedError(..) else {
    fail("expected a reported error")
  }
  assert_true(outcome_text(outcome).contains("query"))
}

///|
async test "memory_search: CLI failure surfaces a bounded stderr excerpt" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:search", { exit: 2, stdout: "", stderr: "boom happened" }),
    ]),
  )
  let ext = tool_ext(runner~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "memory_search",
    tool_call("memory_search", j("{\"query\":\"x\"}")),
  )
  guard outcome is @posoco.ToolOutcome::ToolReportedError(..) else {
    fail("expected a reported error")
  }
  let text = outcome_text(outcome)
  assert_true(text.contains("boom happened"))
  assert_true(text.contains("2"))
}

///|
async test "memory_update: CLI success refreshes the local index entry" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:update", { exit: 0, stdout: "{}", stderr: "" }),
    ]),
  )
  let ext = tool_ext(runner~)
  ext.mem.index.push(mem_entry(id="mem_3", content="old text", title="Old"))
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "memory_update",
    tool_call(
      "memory_update",
      j("{\"id\":\"mem_3\",\"content\":\"new text\",\"title\":\"New\"}"),
    ),
  )
  guard outcome is @posoco.ToolOutcome::Success(..) else {
    fail("expected success")
  }
  inspect(ext.mem.index.length(), content="1")
  inspect(ext.mem.index[0].content, content="new text")
  inspect(
    ext.mem.index[0].metadata.get("title") is Some(Json::String("New")),
    content="true",
  )
  debug_inspect(
    runner.calls[0],
    content=(
      #|["--json", "m", "update", "mem_3", "-c", "new text", "-t", "New"]
    ),
  )
}

///|
async test "memory_delete: hard delete with -f and local index eviction" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:delete", { exit: 0, stdout: "{}", stderr: "" }),
    ]),
  )
  let ext = tool_ext(runner~, expose_delete_tool=true)
  ext.mem.index.push(mem_entry(id="mem_4", content="doomed"))
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "memory_delete",
    tool_call("memory_delete", j("{\"id\":\"mem_4\"}")),
  )
  guard outcome is @posoco.ToolOutcome::Success(..) else {
    fail("expected success")
  }
  inspect(ext.mem.index.length(), content="0")
  debug_inspect(
    runner.calls[0],
    content=(
      #|["--json", "m", "delete", "mem_4", "-f"]
    ),
  )
}

///|
async test "thread_show: applies progressive-loading defaults" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([("t:show", { exit: 0, stdout: "{}", stderr: "" })]),
  )
  let ext = tool_ext(runner~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "thread_show",
    tool_call("thread_show", j("{\"thread_id\":\"th_1\"}")),
  )
  guard outcome is @posoco.ToolOutcome::Success(..) else {
    fail("expected success")
  }
  debug_inspect(
    runner.calls[0],
    content=(
      #|[
      #|  "--json",
      #|  "t",
      #|  "show",
      #|  "th_1",
      #|  "--limit",
      #|  "8",
      #|  "--offset",
      #|  "0",
      #|  "--content-limit",
      #|  "1200",
      #|]
    ),
  )
}

///|
async test "thread_create: curated handoff thread with the generic-agent source" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("t:create", { exit: 0, stdout: "{}", stderr: "" }),
    ]),
  )
  let ext = tool_ext(runner~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "thread_create",
    tool_call(
      "thread_create",
      j("{\"title\":\"Handoff\",\"content\":\"did things\"}"),
    ),
  )
  guard outcome is @posoco.ToolOutcome::Success(..) else {
    fail("expected success")
  }
  debug_inspect(
    runner.calls[0],
    content=(
      #|[
      #|  "--json",
      #|  "t",
      #|  "create",
      #|  "-t",
      #|  "Handoff",
      #|  "-c",
      #|  "did things",
      #|  "-s",
      #|  "generic-agent",
      #|]
    ),
  )
}

///|
async test "execute: unknown tool raises RuntimeError::UnknownTool" {
  let ext = tool_ext()
  try
    @posoco.ToolProvider::execute(
      ext,
      "memory_vaporize",
      tool_call("memory_vaporize", Json::object(Map::from_array([]))),
    )
  catch {
    @posoco.RuntimeError::UnknownTool(_) => ()
    _ => fail("expected UnknownTool")
  } noraise {
    _ => fail("expected execute to raise")
  }
}

///|
async test "read_working_memory: content body, exists=false hint, ambient space" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "wm",
        {
          exit: 0,
          stdout: "{\"content\":\"wm body\",\"exists\":true}",
          stderr: "",
        },
      ),
    ]),
  )
  let ext = tool_ext(runner~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "read_working_memory",
    tool_call("read_working_memory", Json::object(Map::from_array([]))),
  )
  guard outcome is @posoco.ToolOutcome::Success(content~, structured~) else {
    fail("expected success")
  }
  inspect(content, content="wm body")
  inspect(structured is Some(Json::Object(_)), content="true")
  debug_inspect(
    runner.calls[0],
    content=(
      #|["--json", "wm", "read"]
    ),
  )
  // exists=false is a clean state: a hint, not an error.
  let empty_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "wm",
        { exit: 0, stdout: "{\"content\":\"\",\"exists\":false}", stderr: "" },
      ),
    ]),
  )
  let empty_ext = tool_ext(runner=empty_runner)
  let empty = @posoco.ToolProvider::execute(
    empty_ext,
    "read_working_memory",
    tool_call("read_working_memory", Json::object(Map::from_array([]))),
  )
  guard empty is @posoco.ToolOutcome::Success(content=empty_content, ..) else {
    fail("expected success for an empty working memory")
  }
  inspect(empty_content, content=NMEM_WM_EMPTY_HINT)
  // A configured space scopes the read.
  let scoped_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("wm", { exit: 0, stdout: "{\"content\":\"scoped\"}", stderr: "" }),
    ]),
  )
  let scoped_ext = tool_ext(runner=scoped_runner, space=Some("team"))
  let scoped = @posoco.ToolProvider::execute(
    scoped_ext,
    "read_working_memory",
    tool_call("read_working_memory", Json::object(Map::from_array([]))),
  )
  guard scoped is @posoco.ToolOutcome::Success(content=scoped_content, ..) else {
    fail("expected success")
  }
  inspect(scoped_content, content="scoped")
  assert_true(scoped_runner.calls[0].contains("--space"))
  assert_true(scoped_runner.calls[0].contains("team"))
}

///|
async test "read_context_bundle: source-app argv, markdown chain, ambient space" {
  let runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        {
          exit: 0,
          stdout: "{\"rendered_markdown\":\"# Bundle\",\"markdown\":\"shadowed\"}",
          stderr: "",
        },
      ),
    ]),
  )
  let ext = tool_ext(runner~)
  let outcome = @posoco.ToolProvider::execute(
    ext,
    "read_context_bundle",
    tool_call("read_context_bundle", Json::object(Map::from_array([]))),
  )
  guard outcome is @posoco.ToolOutcome::Success(content~, structured~) else {
    fail("expected success")
  }
  inspect(content, content="# Bundle")
  inspect(structured is Some(Json::Object(_)), content="true")
  debug_inspect(
    runner.calls[0],
    content=(
      #|["--json", "context", "--source-app", "posoco"]
    ),
  )
  // rendered_markdown absent: markdown, then content, carry the body.
  let md_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        {
          exit: 0,
          stdout: "{\"markdown\":\"md body\",\"content\":\"shadowed\"}",
          stderr: "",
        },
      ),
    ]),
  )
  let md_ext = tool_ext(runner=md_runner)
  let md = @posoco.ToolProvider::execute(
    md_ext,
    "read_context_bundle",
    tool_call("read_context_bundle", Json::object(Map::from_array([]))),
  )
  guard md is @posoco.ToolOutcome::Success(content=md_content, ..) else {
    fail("expected success")
  }
  inspect(md_content, content="md body")
  let plain_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        { exit: 0, stdout: "{\"content\":\"plain body\"}", stderr: "" },
      ),
    ]),
  )
  let plain_ext = tool_ext(runner=plain_runner)
  let plain = @posoco.ToolProvider::execute(
    plain_ext,
    "read_context_bundle",
    tool_call("read_context_bundle", Json::object(Map::from_array([]))),
  )
  guard plain is @posoco.ToolOutcome::Success(content=plain_content, ..) else {
    fail("expected success")
  }
  inspect(plain_content, content="plain body")
  // A configured space scopes the read.
  let scoped_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      (
        "context",
        { exit: 0, stdout: "{\"rendered_markdown\":\"scoped\"}", stderr: "" },
      ),
    ]),
  )
  let scoped_ext = tool_ext(runner=scoped_runner, space=Some("team"))
  let scoped = @posoco.ToolProvider::execute(
    scoped_ext,
    "read_context_bundle",
    tool_call("read_context_bundle", Json::object(Map::from_array([]))),
  )
  guard scoped is @posoco.ToolOutcome::Success(content=scoped_content, ..) else {
    fail("expected success")
  }
  inspect(scoped_content, content="scoped")
  assert_true(scoped_runner.calls[0].contains("--space"))
  assert_true(scoped_runner.calls[0].contains("team"))
}

///|
async test "official-surface tools attach parsed stdout as structured payload" {
  // memory_search: a parseable object payload passes through verbatim.
  let search_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("m:search", { exit: 0, stdout: "{\"memories\":[]}", stderr: "" }),
    ]),
  )
  let search = @posoco.ToolProvider::execute(
    tool_ext(runner=search_runner),
    "memory_search",
    tool_call("memory_search", j("{\"query\":\"x\"}")),
  )
  guard search
    is @posoco.ToolOutcome::Success(
      content=search_content,
      structured=search_structured
    ) else {
    fail("expected success")
  }
  inspect(search_content, content="{\"memories\":[]}")
  inspect(search_structured is Some(Json::Object(_)), content="true")
  // thread_search: a non-JSON stdout keeps structured None, content verbatim.
  let thread_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("t:search", { exit: 0, stdout: "plain text table", stderr: "" }),
    ]),
  )
  let thread = @posoco.ToolProvider::execute(
    tool_ext(runner=thread_runner),
    "thread_search",
    tool_call("thread_search", j("{\"query\":\"x\"}")),
  )
  guard thread
    is @posoco.ToolOutcome::Success(
      content=thread_content,
      structured=thread_structured
    ) else {
    fail("expected success")
  }
  inspect(thread_content, content="plain text table")
  inspect(thread_structured is None, content="true")
  // nmem_status: a parseable object payload passes through verbatim.
  let status_runner = FakeRunner::FakeRunner(
    replies=Map::from_array([
      ("status", { exit: 0, stdout: "{\"mode\":\"local\"}", stderr: "" }),
    ]),
  )
  let status = @posoco.ToolProvider::execute(
    tool_ext(runner=status_runner),
    "nmem_status",
    tool_call("nmem_status", Json::object(Map::from_array([]))),
  )
  guard status is @posoco.ToolOutcome::Success(structured=status_structured, ..) else {
    fail("expected success")
  }
  inspect(status_structured is Some(Json::Object(_)), content="true")
}
