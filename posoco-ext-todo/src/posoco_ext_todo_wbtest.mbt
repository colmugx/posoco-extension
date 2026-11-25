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
fn tk_call(name : String, arguments : Json) -> @posoco.ToolCallContext {
  @tk.tk_tool_call_ctx(name~, arguments~)
}

///|
fn item_json(id : String, content : String, status : String) -> Json {
  Json::object({
    "id": Json::string(id),
    "content": Json::string(content),
    "status": Json::string(status),
  })
}

///|
/// `{id: "t<i>", content, status}` items in order, wrapped for a write.
fn todos_json(entries : Array[(String, String)]) -> Json {
  let items : Array[Json] = []
  for i, entry in entries {
    let (content, status) = entry
    items.push(item_json("t\{i + 1}", content, status))
  }
  Json::object({ "todos": Json::array(items) })
}

///|
fn write_call(entries : Array[(String, String)]) -> @posoco.ToolCallContext {
  tk_call("todo_write", todos_json(entries))
}

///|
/// A `merge=true` write carrying exactly the given item objects.
fn merge_call(items : Array[Json]) -> @posoco.ToolCallContext {
  tk_call(
    "todo_write",
    Json::object({ "merge": Json::boolean(true), "todos": Json::array(items) }),
  )
}

///|
async fn expect_write_error(
  todo : TodoList,
  arguments : Json,
  needle : String,
) -> Unit {
  match todo.execute(tk_call("todo_write", arguments)) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains(needle))
    _ => fail("expected ToolReportedError")
  }
}

///|
async test "todo_write replaces the list and bumps the revision" {
  let todo = TodoList::TodoList()
  match
    todo.execute(write_call([("first", "in_progress"), ("second", "pending")])) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success")
  }
  assert_eq(todo.items().length(), 2)
  assert_eq(todo.items()[0].id, "t1")
  // Priority is optional and defaults to medium.
  assert_eq(todo.items()[0].priority, TodoPriority::Medium)
  assert_eq(todo.revision(), 1)
  // Full replacement: a new call swaps every entry, ids included.
  match
    todo.execute(
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
async test "todo_write result text carries ids and a structured summary" {
  let todo = TodoList::TodoList()
  match
    todo.execute(
      write_call([
        ("survey", "completed"),
        ("patch", "in_progress"),
        ("ship", "pending"),
      ]),
    ) {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_true(content.contains("revision 1"))
      assert_true(content.contains("[x] 1. survey (id=t1)"))
      assert_true(content.contains("[>] 2. patch (id=t2)"))
      assert_true(content.contains("[ ] 3. ship (id=t3)"))
      assert_eq(
        structured,
        Some(
          Json::object({
            "summary": Json::string(
              "3 tasks: 1 completed, 1 in progress, 1 pending, 0 cancelled",
            ),
            "revision": Json::number(1.0),
            "total": Json::number(3.0),
            "completed": Json::number(1.0),
            "in_progress": Json::number(1.0),
            "pending": Json::number(1.0),
            "cancelled": Json::number(0.0),
            "items": Json::array([
              Json::object({
                "id": Json::string("t1"),
                "content": Json::string("survey"),
                "status": Json::string("completed"),
                "priority": Json::string("medium"),
              }),
              Json::object({
                "id": Json::string("t2"),
                "content": Json::string("patch"),
                "status": Json::string("in_progress"),
                "priority": Json::string("medium"),
              }),
              Json::object({
                "id": Json::string("t3"),
                "content": Json::string("ship"),
                "status": Json::string("pending"),
                "priority": Json::string("medium"),
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
async test "merge updates existing items by id and appends new ones" {
  let todo = TodoList::TodoList()
  ignore(
    todo.execute(
      write_call([("Build project", "in_progress"), ("Run tests", "pending")]),
    ),
  )
  // Flip a status without echoing content (blank keeps the text); append a
  // new item with an explicit priority.
  match
    todo.execute(
      merge_call([
        item_json("t1", "", "completed"),
        Json::object({
          "id": Json::string("deploy"),
          "content": Json::string("Deploy"),
          "status": Json::string("pending"),
          "priority": Json::string("high"),
        }),
      ]),
    ) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success")
  }
  let items = todo.items()
  assert_eq(items.length(), 3)
  // Existing items keep their position and text; the status flips in place.
  assert_eq(items[0].content, "Build project")
  assert_eq(items[0].status, TodoStatus::Completed)
  assert_eq(items[1].status, TodoStatus::Pending)
  assert_eq(items[2].id, "deploy")
  assert_eq(items[2].priority, TodoPriority::High)
  assert_eq(todo.revision(), 2)
}

///|
async test "merge keeps content and priority when they are omitted" {
  let todo = TodoList::TodoList()
  ignore(
    todo.execute(
      tk_call(
        "todo_write",
        Json::object({
          "todos": Json::array([
            Json::object({
              "id": Json::string("explore"),
              "content": Json::string("Explore the code"),
              "status": Json::string("pending"),
              "priority": Json::string("high"),
            }),
          ]),
        }),
      ),
    ),
  )
  // Status-only update: no content and no priority key at all.
  match
    todo.execute(
      merge_call([
        Json::object({
          "id": Json::string("explore"),
          "status": Json::string("in_progress"),
        }),
      ]),
    ) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success")
  }
  let items = todo.items()
  assert_eq(items.length(), 1)
  assert_eq(items[0].content, "Explore the code")
  assert_eq(items[0].status, TodoStatus::InProgress)
  assert_eq(items[0].priority, TodoPriority::High)
}

///|
async test "merge rejects a new id without content and leaves the list untouched" {
  let todo = TodoList::TodoList()
  ignore(todo.execute(write_call([("existing", "pending")])))
  expect_write_error(
    todo,
    Json::object({
      "merge": Json::boolean(true),
      "todos": Json::array([
        Json::object({
          "id": Json::string("fresh"),
          "status": Json::string("pending"),
        }),
      ]),
    }),
    "content is required for new id 'fresh'",
  )
  assert_eq(todo.items().length(), 1)
  assert_eq(todo.revision(), 1)
}

///|
async test "an empty todos array clears the list only without merge" {
  let todo = TodoList::TodoList()
  ignore(todo.execute(write_call([("a", "pending")])))
  // Merging nothing changes nothing.
  match todo.execute(merge_call([])) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success")
  }
  assert_eq(todo.items().length(), 1)
  assert_eq(todo.revision(), 2)
  match todo.execute(tk_call("todo_write", todos_json([]))) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("no todos"))
    _ => fail("expected Success")
  }
  assert_eq(todo.items().length(), 0)
  assert_eq(todo.revision(), 3)
}

///|
async test "cancelled items stay visible and count separately" {
  let todo = TodoList::TodoList()
  ignore(
    todo.execute(
      write_call([
        ("survey", "completed"),
        ("patch", "in_progress"),
        ("docs", "cancelled"),
      ]),
    ),
  )
  match todo.execute(tk_call("todo_read", Json::null())) {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_true(content.contains("[-] 3. docs (id=t3)"))
      match structured {
        Some(Json::Object(fields)) =>
          assert_eq(fields.get("cancelled"), Some(Json::number(1.0)))
        _ => fail("expected an object payload")
      }
    }
    _ => fail("expected Success")
  }
  match todo.invoke("todo", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_true(
        feedback.contains("1 completed, 1 in progress, 0 pending, 1 cancelled"),
      )
      assert_true(feedback.contains("[-] 3. docs"))
    }
    _ => fail("expected Success")
  }
}

///|
async test "several in_progress items are accepted; the limit is guidance only" {
  let todo = TodoList::TodoList()
  match todo.execute(write_call([("a", "in_progress"), ("b", "in_progress")])) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success for parallel work")
  }
  assert_eq(todo.items()[1].status, TodoStatus::InProgress)
}

///|
async test "todo_write enforces the list size limit in both modes" {
  let todo = TodoList::TodoList()
  let exact : Array[Json] = []
  for i in 0..<MAX_TODOS {
    exact.push(item_json("t\{i}", "task \{i}", "pending"))
  }
  // The limit itself is accepted.
  match
    todo.execute(
      tk_call("todo_write", Json::object({ "todos": Json::array(exact) })),
    ) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success at the limit")
  }
  // A merge that would grow past the limit is rejected as a whole.
  expect_write_error(
    todo,
    Json::object({
      "merge": Json::boolean(true),
      "todos": Json::array([
        item_json("t0", "", "completed"),
        item_json("overflow", "one too many", "pending"),
      ]),
    }),
    "limited to \{MAX_TODOS} entries (got \{MAX_TODOS + 1})",
  )
  // So is a full replacement one over the limit.
  let too_many = exact.copy()
  too_many.push(item_json("overflow", "one too many", "pending"))
  expect_write_error(
    todo,
    Json::object({ "todos": Json::array(too_many) }),
    "limited to \{MAX_TODOS} entries",
  )
  assert_eq(todo.items().length(), MAX_TODOS)
  assert_eq(todo.items()[0].status, TodoStatus::Pending)
  assert_eq(todo.revision(), 1)
  // Merging within the limit still flips statuses in place.
  match todo.execute(merge_call([item_json("t0", "", "completed")])) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success")
  }
  assert_eq(todo.items()[0].status, TodoStatus::Completed)
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
  // Missing or mistyped todos array / merge flag.
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
  expect_write_error(
    todo,
    Json::object({ "merge": Json::string("yes"), "todos": Json::array([]) }),
    "'merge' must be a boolean",
  )
  // Item-level shape errors.
  expect_write_error(
    todo,
    Json::object({ "todos": Json::array([Json::string("no")]) }),
    "must be an object with 'id' and 'status'",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({
          "content": Json::string("x"),
          "status": Json::string("pending"),
        }),
      ]),
    }),
    "is missing 'id'",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({
          "id": Json::string("  "),
          "status": Json::string("pending"),
        }),
      ]),
    }),
    "id must be a non-empty string",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({
          "id": Json::number(1),
          "status": Json::string("pending"),
        }),
      ]),
    }),
    "id must be a string",
  )
  // Replace mode requires content.
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({
          "id": Json::string("a"),
          "status": Json::string("pending"),
        }),
      ]),
    }),
    "is missing 'content'",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({
          "id": Json::string("a"),
          "content": Json::string("  "),
          "status": Json::string("pending"),
        }),
      ]),
    }),
    "content must be a non-empty string",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({
          "id": Json::string("a"),
          "content": Json::number(1),
          "status": Json::string("pending"),
        }),
      ]),
    }),
    "content must be a string",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({ "id": Json::string("a"), "content": Json::string("x") }),
      ]),
    }),
    "is missing 'status'",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({
          "id": Json::string("a"),
          "content": Json::string("x"),
          "status": Json::number(1),
        }),
      ]),
    }),
    "status must be a string",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({
          "id": Json::string("a"),
          "content": Json::string("x"),
          "status": Json::string("done"),
        }),
      ]),
    }),
    "status must be one of pending | in_progress | completed | cancelled",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({
          "id": Json::string("a"),
          "content": Json::string("x"),
          "status": Json::string("pending"),
          "priority": Json::string("urgent"),
        }),
      ]),
    }),
    "priority must be one of high | medium | low",
  )
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        Json::object({
          "id": Json::string("a"),
          "content": Json::string("x"),
          "status": Json::string("pending"),
          "priority": Json::number(1),
        }),
      ]),
    }),
    "priority must be a string",
  )
  // Duplicate ids within one call, in either mode.
  let dup = Json::array([
    item_json("dup", "a", "pending"),
    item_json("dup", "b", "pending"),
  ])
  expect_write_error(
    todo,
    Json::object({ "todos": dup }),
    "'dup' is duplicated in this call",
  )
  expect_write_error(
    todo,
    Json::object({ "merge": Json::boolean(true), "todos": dup }),
    "'dup' is duplicated in this call",
  )
  assert_eq(todo.revision(), 0)
  assert_eq(todo.items().length(), 0)
}

///|
async test "todo_read reports the empty list" {
  let todo = TodoList::TodoList()
  match todo.execute(tk_call("todo_read", Json::null())) {
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
            "cancelled": Json::number(0.0),
            "items": Json::array([]),
          }),
        ),
      )
    }
    _ => fail("expected Success")
  }
}

///|
async test "todo_read returns the current list with ids" {
  let todo = TodoList::TodoList()
  ignore(
    todo.execute(
      write_call([("survey", "completed"), ("patch", "in_progress")]),
    ),
  )
  match todo.execute(tk_call("todo_read", Json::null())) {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_true(content.contains("revision 1"))
      assert_true(content.contains("[x] 1. survey (id=t1)"))
      assert_true(content.contains("[>] 2. patch (id=t2)"))
    }
    _ => fail("expected Success")
  }
}

///|
async test "every successful write pushes one Widget render intent without ids" {
  let ui = RecordingUi()
  let todo = TodoList::TodoList()
  todo.ui = ui as &@posoco.UiPort
  ignore(todo.execute(write_call([("a", "in_progress"), ("b", "cancelled")])))
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
      assert_eq(lines[1], "[-] 2. b")
    }
    _ => fail("expected a Lines body")
  }
  // Same key replaces: a merge refreshes the single region.
  ignore(todo.execute(merge_call([item_json("t2", "", "completed")])))
  assert_eq(ui.renders.length(), 2)
  match ui.renders[1].body {
    @posoco.UiBody::Lines(lines) => {
      assert_eq(lines.length(), 2)
      assert_eq(lines[1], "[x] 2. b")
    }
    _ => fail("expected a Lines body")
  }
}

///|
async test "rejected writes render nothing" {
  let ui = RecordingUi()
  let todo = TodoList::TodoList()
  todo.ui = ui as &@posoco.UiPort
  ignore(todo.execute(write_call([("good", "pending")])))
  assert_eq(ui.renders.length(), 1)
  expect_write_error(
    todo,
    Json::object({
      "todos": Json::array([
        item_json("dup", "bad", "pending"),
        item_json("dup", "worse", "pending"),
      ]),
    }),
    "duplicated",
  )
  assert_eq(ui.renders.length(), 1)
}

///|
async test "without a composed UI writes still succeed" {
  // The default is NoopUiPort: pre-compose and headless hosts are no-ops.
  let todo = TodoList::TodoList()
  match todo.execute(write_call([("a", "pending")])) {
    @posoco.ToolOutcome::Success(..) => ()
    _ => fail("expected Success without a UI")
  }
  assert_eq(todo.revision(), 1)
}

///|
async test "on_compose stores the composed UI and writes render through it" {
  let ui = RecordingUi()
  let model = @tk.ScriptedModel([])
  let todo = TodoList::TodoList()
  todo.on_compose(
    @tk.tk_view(
      requires=[@posoco.Capability::Ui],
      model=model as &@posoco.ModelPort,
      ui=ui as &@posoco.UiPort,
    ),
  )
  ignore(todo.execute(write_call([("a", "pending")])))
  assert_eq(ui.renders.length(), 1)
  assert_eq(ui.renders[0].key, "todo")
}

///|
async test "/todo command renders the list without ids or state changes" {
  let todo = TodoList::TodoList()
  match todo.invoke("todo", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("Todo list is empty"))
    _ => fail("expected Success on the empty list")
  }
  ignore(
    todo.execute(
      write_call([("survey", "completed"), ("patch", "in_progress")]),
    ),
  )
  let revision_before = todo.revision()
  match todo.invoke("todo", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      assert_true(feedback.contains("revision 1"))
      assert_true(
        feedback.contains(
          "2 tasks: 1 completed, 1 in progress, 0 pending, 0 cancelled",
        ),
      )
      assert_true(feedback.contains("1/2 done"))
      assert_true(feedback.contains("[x] 1. survey"))
      assert_true(feedback.contains("[>] 2. patch"))
      // The user view never leaks item ids.
      assert_false(feedback.contains("id="))
      match structured {
        Some(Json::Object(fields)) => {
          assert_eq(fields.get("revision"), Some(Json::number(1.0)))
          assert_eq(fields.get("total"), Some(Json::number(2.0)))
        }
        _ => fail("expected an object payload")
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
/// Collect every JSON string in a schema tree — object keys included — used
/// to assert property names and enums without leaning on the deprecated Show
/// rendering of Json.
fn collect_strings(json : Json, acc : Array[String]) -> Unit {
  match json {
    String(text) => acc.push(text)
    Array(items) =>
      for item in items {
        collect_strings(item, acc)
      }
    Object(fields) =>
      for key, value in fields {
        acc.push(key)
        collect_strings(value, acc)
      }
    _ => ()
  }
}

///|
async test "list_tools declares the Cursor-shaped schema on Sequential tools" {
  let todo = TodoList::TodoList()
  let tools = todo.list_tools()
  assert_eq(tools.length(), 2)
  assert_eq(tools[0].name.to_string(), "todo_write")
  assert_eq(tools[1].name.to_string(), "todo_read")
  assert_true(tools[0].description.contains("at most one in_progress"))
  assert_false(tools[0].description.contains("exactly ONE"))
  // Both touch one shared list: never share a parallel wave.
  assert_eq(tools[0].policy, @posoco.ExecutionPolicy::Sequential)
  assert_eq(tools[1].policy, @posoco.ExecutionPolicy::Sequential)
  let schema_strings : Array[String] = []
  collect_strings(tools[0].input_schema, schema_strings)
  let expected : Array[String] = [
    "merge", "id", "content", "status", "priority", "pending", "in_progress", "completed",
    "cancelled", "high", "medium", "low",
  ]
  for needle in expected {
    assert_true(schema_strings.contains(needle))
  }
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
test "system_prompt teaches the merge workflow" {
  let todo = TodoList::TodoList()
  let prompt = todo.system_prompt()
  assert_true(prompt.contains("todo_write"))
  assert_true(prompt.contains("todo_read"))
  assert_true(prompt.contains("merge=true"))
  assert_true(prompt.contains("cancelled"))
  assert_true(prompt.contains("at most one task in_progress"))
  // Byte-stable across calls.
  assert_eq(todo.system_prompt(), prompt)
}
