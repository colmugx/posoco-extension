///|
/// Tests for posoco_ext_todo.

///|
/// Recording UiPort fake: captures every render intent for post-hoc
/// assertions. Services no interactive requests.
priv struct RecordingUi {
  renders : Array[@posoco.UiRender]
}

///|
fn RecordingUi::RecordingUi() -> RecordingUi {
  { renders: [], }
}

///|
impl @posoco.UiPort for RecordingUi with fn ui_descriptor(_self : RecordingUi) -> @posoco.UiDescriptor {
  @posoco.UiDescriptor::empty()
}

///|
impl @posoco.UiPort for RecordingUi with fn render(
  self : RecordingUi,
  intent : @posoco.UiRender,
) -> Unit {
  self.renders.push(intent)
}

///|
impl @posoco.UiPort for RecordingUi with fn request(
  _self : RecordingUi,
  _req : @posoco.UiRequest,
) -> @posoco.UiResponse {
  raise @posoco.UiError::Unsupported(
    detail="RecordingUi does not service requests",
  )
}

///|
fn tk_call_with_args(name : String, arguments : Json) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked(name),
    arguments,
  }
}

///|
fn todos_json(entries : Array[(String, String)]) -> Json {
  Json::object({
    "todos": Json::array(
      entries.map(entry => {
        let (content, status) = entry
        Json::object({
          "content": Json::string(content),
          "status": Json::string(status),
        })
      }),
    ),
  })
}

///|
fn write_call(entries : Array[(String, String)]) -> @posoco.ToolCall {
  tk_call_with_args("todo_write", todos_json(entries))
}

///|
async fn expect_write_error(
  todo : TodoList,
  arguments : Json,
  needle : String,
) -> Unit {
  match todo.execute("todo_write", tk_call_with_args("todo_write", arguments)) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains(needle))
    _ => fail("expected ToolReportedError")
  }
}

///|
async test "todo_write replaces the list and bumps the revision" {
  let todo = TodoList::TodoList()
  match
    todo.execute(
      "todo_write",
      write_call([("first", "in_progress"), ("second", "pending")]),
    ) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success")
  }
  assert_eq(todo.items().length(), 2)
  assert_eq(todo.revision(), 1)
  // Full replacement: a new call swaps every entry.
  match
    todo.execute(
      "todo_write",
      write_call([
        ("only", "pending"),
        ("another", "pending"),
        ("third", "completed"),
      ]),
    ) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success")
  }
  assert_eq(todo.items().length(), 3)
  assert_eq(todo.items()[0].content, "only")
  assert_eq(todo.items()[2].status, TodoStatus::Completed)
  assert_eq(todo.revision(), 2)
}

///|
async test "todo_write result text is the rendered preview with a structured summary" {
  let todo = TodoList::TodoList()
  match
    todo.execute(
      "todo_write",
      write_call([
        ("survey", "completed"),
        ("patch", "in_progress"),
        ("ship", "pending"),
      ]),
    ) {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_true(content.contains("revision 1"))
      assert_true(content.contains("[x] 1. survey"))
      assert_true(content.contains("[>] 2. patch"))
      assert_true(content.contains("[ ] 3. ship"))
      assert_eq(
        structured,
        Some(
          Json::object({
            "summary": Json::string(
              "3 tasks: 1 completed, 1 in progress, 1 pending",
            ),
            "revision": Json::number(1.0),
            "total": Json::number(3.0),
            "completed": Json::number(1.0),
            "in_progress": Json::number(1.0),
            "pending": Json::number(1.0),
            "items": Json::array([
              Json::object({
                "content": Json::string("survey"),
                "status": Json::string("completed"),
              }),
              Json::object({
                "content": Json::string("patch"),
                "status": Json::string("in_progress"),
              }),
              Json::object({
                "content": Json::string("ship"),
                "status": Json::string("pending"),
              }),
            ]),
          }),
        ),
      )
    }
    _ => fail("expected Success")
  }
}

///|
async test "todo_write rejects an empty content" {
  let todo = TodoList::TodoList()
  expect_write_error(
    todo,
    todos_json([("  ", "pending")]),
    "content must be a non-empty string",
  )
  assert_eq(todo.revision(), 0)
}

///|
async test "todo_write rejects an unknown status" {
  let todo = TodoList::TodoList()
  expect_write_error(
    todo,
    todos_json([("task", "done")]),
    "status must be one of pending | in_progress | completed",
  )
}

///|
async test "todo_write enforces the list size limit" {
  let todo = TodoList::TodoList()
  let too_many : Array[Json] = []
  for i in 0..<(MAX_TODOS + 1) {
    too_many.push(
      Json::object({
        "content": Json::string("task \{i}"),
        "status": Json::string("pending"),
      }),
    )
  }
  expect_write_error(
    todo,
    Json::object({ "todos": Json::array(too_many) }),
    "limited to \{MAX_TODOS} entries",
  )
  // The limit itself is accepted.
  let exact : Array[Json] = []
  for i in 0..<MAX_TODOS {
    exact.push(
      Json::object({
        "content": Json::string("task \{i}"),
        "status": Json::string("pending"),
      }),
    )
  }
  match
    todo.execute(
      "todo_write",
      tk_call_with_args(
        "todo_write",
        Json::object({ "todos": Json::array(exact) }),
      ),
    ) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success at the limit")
  }
}

///|
async test "todo_write allows at most one in_progress" {
  let todo = TodoList::TodoList()
  // Exactly one in_progress is accepted.
  match
    todo.execute(
      "todo_write",
      write_call([("a", "in_progress"), ("b", "pending")]),
    ) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success for a single in_progress")
  }
  assert_eq(todo.items()[0].status, TodoStatus::InProgress)
  expect_write_error(
    todo,
    todos_json([("a", "in_progress"), ("b", "in_progress")]),
    "at most one task may be in_progress (got 2)",
  )
}

///|
async test "todo_write rejects malformed arguments" {
  let todo = TodoList::TodoList()
  // Not an object.
  expect_write_error(todo, Json::null(), "arguments must be a JSON object")
  expect_write_error(
    todo,
    Json::string("no"),
    "arguments must be a JSON object",
  )
  // Missing or mistyped todos array.
  expect_write_error(
    todo,
    Json::object(Map::from_array([])),
    "missing 'todos' argument",
  )
  expect_write_error(
    todo,
    Json::object({ "todos": Json::string("no") }),
    "'todos' must be an array",
  )
  // Item-level shape errors.
  expect_write_error(
    todo,
    Json::object({ "todos": Json::array([Json::string("no")]) }),
    "must be an object with 'content' and 'status'",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([Json::object({ "status": Json::string("pending") })]),
    }),
    "is missing 'content'",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([Json::object({ "content": Json::number(1) })]),
    }),
    "content must be a string",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([Json::object({ "content": Json::string("x") })]),
    }),
    "is missing 'status'",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({ "content": Json::string("x"), "status": Json::number(1) }),
      ]),
    }),
    "status must be a string",
  )
  assert_eq(todo.revision(), 0)
  assert_eq(todo.items().length(), 0)
}

///|
async test "todo_read reports the empty list" {
  let todo = TodoList::TodoList()
  match
    todo.execute("todo_read", tk_call_with_args("todo_read", Json::null())) {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_true(content.contains("Todo list is empty"))
      assert_true(content.contains("todo_write"))
      assert_eq(
        structured,
        Some(
          Json::object({
            "summary": Json::string("no todos"),
            "revision": Json::number(0.0),
            "total": Json::number(0.0),
            "completed": Json::number(0.0),
            "in_progress": Json::number(0.0),
            "pending": Json::number(0.0),
            "items": Json::array([]),
          }),
        ),
      )
    }
    _ => fail("expected Success")
  }
}

///|
async test "todo_read returns the current list" {
  let todo = TodoList::TodoList()
  ignore(
    todo.execute(
      "todo_write",
      write_call([("survey", "completed"), ("patch", "in_progress")]),
    ),
  )
  match
    todo.execute("todo_read", tk_call_with_args("todo_read", Json::null())) {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_true(content.contains("revision 1"))
      assert_true(content.contains("[x] 1. survey"))
      assert_true(content.contains("[>] 2. patch"))
    }
    _ => fail("expected Success")
  }
}

///|
async test "an empty todos array clears the list" {
  let todo = TodoList::TodoList()
  ignore(todo.execute("todo_write", write_call([("a", "pending")])))
  match
    todo.execute("todo_write", tk_call_with_args("todo_write", todos_json([]))) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("no todos"))
    _ => fail("expected Success")
  }
  assert_eq(todo.items().length(), 0)
  assert_eq(todo.revision(), 2)
}

///|
async test "every successful write pushes one Widget render intent" {
  let ui = RecordingUi()
  let todo = TodoList::TodoList()
  todo.ui = ui as &@posoco.UiPort
  ignore(
    todo.execute(
      "todo_write",
      write_call([("a", "in_progress"), ("b", "pending")]),
    ),
  )
  assert_eq(ui.renders.length(), 1)
  let render = ui.renders[0]
  assert_eq(render.slot, @posoco.UiSlot::Widget)
  assert_eq(render.key, "todo")
  assert_eq(render.title, Some("Todos"))
  assert_eq(render.ttl_ms, None)
  match render.body {
    @posoco.UiBody::Lines(lines) => {
      assert_eq(lines.length(), 2)
      assert_eq(lines[0], "[>] 1. a")
      assert_eq(lines[1], "[ ] 2. b")
    }
    _ => fail("expected a Lines body")
  }
  // Same key replaces: the second write refreshes the single region.
  ignore(todo.execute("todo_write", write_call([("c", "pending")])))
  assert_eq(ui.renders.length(), 2)
  match ui.renders[1].body {
    @posoco.UiBody::Lines(lines) => assert_eq(lines.length(), 1)
    _ => fail("expected a Lines body")
  }
}

///|
async test "rejected writes render nothing" {
  let ui = RecordingUi()
  let todo = TodoList::TodoList()
  todo.ui = ui as &@posoco.UiPort
  ignore(todo.execute("todo_write", write_call([("good", "pending")])))
  assert_eq(ui.renders.length(), 1)
  expect_write_error(
    todo,
    todos_json([("bad", "in_progress"), ("worse", "in_progress")]),
    "at most one",
  )
  assert_eq(ui.renders.length(), 1)
}

///|
async test "without a composed UI writes still succeed" {
  // The default is NoopUiPort: pre-compose and headless hosts are no-ops.
  let todo = TodoList::TodoList()
  match todo.execute("todo_write", write_call([("a", "pending")])) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success without a UI")
  }
  assert_eq(todo.revision(), 1)
}

///|
async test "on_compose stores the composed UI and writes render through it" {
  let ui = RecordingUi()
  let model = @posoco.ScriptedModel([])
  let todo = TodoList::TodoList()
  todo.on_compose(
    @posoco.tk_view(
      requires=[@posoco.Capability::Ui],
      model=model as &@posoco.ModelPort,
      ui=ui as &@posoco.UiPort,
    ),
  )
  ignore(todo.execute("todo_write", write_call([("a", "pending")])))
  assert_eq(ui.renders.length(), 1)
  assert_eq(ui.renders[0].key, "todo")
}

///|
async test "/todo command renders the list without touching state" {
  let todo = TodoList::TodoList()
  match todo.invoke("todo", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("Todo list is empty"))
    _ => fail("expected Success on the empty list")
  }
  ignore(
    todo.execute(
      "todo_write",
      write_call([("survey", "completed"), ("patch", "in_progress")]),
    ),
  )
  let revision_before = todo.revision()
  match todo.invoke("todo", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      assert_true(feedback.contains("revision 1"))
      assert_true(feedback.contains("1/2 done"))
      assert_true(feedback.contains("[x] 1. survey"))
      assert_true(feedback.contains("[>] 2. patch"))
      match structured {
        Some(state) =>
          match state {
            Object(fields) => {
              assert_eq(fields.get("revision"), Some(Json::number(1.0)))
              assert_eq(fields.get("total"), Some(Json::number(2.0)))
            }
            _ => fail("expected an object payload")
          }
        None => fail("expected structured state")
      }
      assert_eq(ui_hint, None)
    }
    _ => fail("expected Success")
  }
  // Pure read: no revision bump.
  assert_eq(todo.revision(), revision_before)
}

///|
async test "unknown command id raises NotFound" {
  let todo = TodoList::TodoList()
  try todo.invoke("nope", Json::null()) catch {
    @posoco.CommandError::NotFound(id) => assert_eq(id, "nope")
    other => fail("expected NotFound, got \{other}")
  } noraise {
    _ => fail("expected NotFound for unknown command id")
  }
}

///|
/// Collect every JSON string in a schema tree, used to assert the status
/// enum without leaning on the deprecated Show rendering of Json.
fn collect_strings(json : Json, acc : Array[String]) -> Unit {
  match json {
    String(text) => acc.push(text)
    Array(items) =>
      for item in items {
        collect_strings(item, acc)
      }
    Object(fields) =>
      for _key, value in fields {
        collect_strings(value, acc)
      }
    _ => ()
  }
}

///|
async test "list_tools declares both tools with the in_progress constraint" {
  let todo = TodoList::TodoList()
  let tools = todo.list_tools()
  assert_eq(tools.length(), 2)
  assert_eq(tools[0].name.to_string(), "todo_write")
  assert_eq(tools[1].name.to_string(), "todo_read")
  assert_true(
    tools[0].description.contains("exactly ONE task may be 'in_progress'"),
  )
  let schema_strings : Array[String] = []
  collect_strings(tools[0].input_schema, schema_strings)
  assert_true(schema_strings.contains("in_progress"))
  assert_true(schema_strings.contains("pending"))
  assert_true(schema_strings.contains("completed"))
  assert_true(schema_strings.contains("todos"))
}

///|
test "extension manifest wires the port views and requires Ui" {
  let todo = TodoList::TodoList()
  assert_eq(todo.extension_id(), "posoco_ext_todo")
  let manifest = todo.manifest()
  assert_eq(manifest.id, "posoco_ext_todo")
  assert_eq(manifest.tools.length(), 1)
  assert_eq(manifest.commands.length(), 1)
  assert_eq(manifest.prompt_contributors.length(), 1)
  assert_eq(manifest.lifecycle.length(), 1)
  // The decisive shape: consume UI, never provide it.
  assert_eq(manifest.requires, [@posoco.Capability::Ui])
  assert_eq(manifest.ui.length(), 0)
  assert_eq(manifest.models.length(), 0)
  assert_eq(manifest.observers.length(), 0)
  assert_eq(manifest.hooks.length(), 0)
}

///|
test "system_prompt teaches the todo workflow" {
  let todo = TodoList::TodoList()
  let prompt = todo.system_prompt()
  assert_true(prompt.contains("todo_write"))
  assert_true(prompt.contains("todo_read"))
  assert_true(prompt.contains("ONE task in_progress"))
  // Byte-stable across calls.
  assert_eq(todo.system_prompt(), prompt)
}
