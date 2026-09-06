///|
/// posoco_ext_todo — a TodoWrite-style task list extension for Posoco.
///
/// The model maintains a structured checklist through the `todo_write` /
/// `todo_read` tools. Hosts learn about the list through render intents:
/// every successful write pushes one `UiPort::render` Widget intent
/// (key `"todo"`) through the composed UI, and the `/todo` command shows
/// the list to the user. The extension is a UI consumer, not a UI provider
/// (`requires: [Capability::Ui]`, empty `ui` manifest slot).
///
/// State is an in-process session list with a monotonic revision counter —
/// no file persistence in v1: restarting the process starts from an empty
/// list. Durable persistence is left to a later milestone.
///
/// Usage:
///   let todos = TodoList::TodoList()
///   let agent = Agent(exts=[todos], config=...)

///|
/// Lifecycle state of one task.
pub(all) enum TodoStatus {
  Pending
  InProgress
  Completed
} derive(Eq, Debug)

///|
/// Wire/display spelling of the status — also the `todo_write` enum values.
pub impl Show for TodoStatus with fn to_string(self) -> String {
  match self {
    Pending => "pending"
    InProgress => "in_progress"
    Completed => "completed"
  }
}

///|
fn TodoStatus::parse(text : String) -> TodoStatus? {
  match text {
    "pending" => Some(Pending)
    "in_progress" => Some(InProgress)
    "completed" => Some(Completed)
    _ => None
  }
}

///|
/// One checklist entry: short imperative content plus lifecycle status.
pub(all) struct TodoItem {
  content : String
  status : TodoStatus
} derive(Eq, Debug)

///|
/// Upper bound on list length accepted by `todo_write`.
pub const MAX_TODOS : Int = 50

///|
fn status_marker(status : TodoStatus) -> String {
  match status {
    Completed => "[x]"
    InProgress => "[>]"
    Pending => "[ ]"
  }
}

///|
fn count_status(items : Array[TodoItem], status : TodoStatus) -> Int {
  items.iter().filter(item => item.status == status).count()
}

///|
/// The checklist body: one line per task, in list order.
fn render_lines(items : Array[TodoItem]) -> Array[String] {
  let lines : Array[String] = []
  for i, item in items {
    lines.push("\{status_marker(item.status)} \{i + 1}. \{item.content}")
  }
  lines
}

///|
/// Full text projection: a progress header, then the checklist lines. The
/// shared view used by the tool result preview and the `/todo` command.
pub fn render_todos(items : Array[TodoItem]) -> String {
  if items.is_empty() {
    return "(no todos)"
  }
  let done = count_status(items, Completed)
  let lines : Array[String] = ["\{done}/\{items.length()} done"]
  for line in render_lines(items) {
    lines.push(line)
  }
  lines.join("\n")
}

///|
/// One-line row text, e.g. "3 tasks: 1 completed, 1 in progress, 1 pending".
fn summary_line(items : Array[TodoItem]) -> String {
  if items.is_empty() {
    return "no todos"
  }
  let completed = count_status(items, Completed)
  let in_progress = count_status(items, InProgress)
  let pending = count_status(items, Pending)
  "\{items.length()} tasks: \{completed} completed, \{in_progress} in progress, \{pending} pending"
}

///|
/// Structured payload carried by tool results and command outcomes. The
/// reserved `summary` field holds the one-line row text a UI shows; `items`
/// mirrors the list for machine-readable observers.
fn structured_state(items : Array[TodoItem], revision : Int) -> Json {
  Json::object(
    Map::from_array([
      ("summary", Json::string(summary_line(items))),
      ("revision", Json::number(revision.to_double())),
      ("total", Json::number(items.length().to_double())),
      ("completed", Json::number(count_status(items, Completed).to_double())),
      ("in_progress", Json::number(count_status(items, InProgress).to_double())),
      ("pending", Json::number(count_status(items, Pending).to_double())),
      (
        "items",
        Json::array(
          items.map(item => {
            Json::object(
              Map::from_array([
                ("content", Json::string(item.content)),
                ("status", Json::string(item.status.to_string())),
              ]),
            )
          }),
        ),
      ),
    ]),
  )
}

///|
/// The todo list extension: one struct, several port views — `ToolProvider`
/// (todo_write / todo_read), `CommandPort` (/todo), `SystemPromptContributor`
/// (usage guidance), `Lifecycle` (receives the composed UI), and `Extension`
/// (self-reporting manifest).
pub struct TodoList {
  /// The composed UI, delivered at `Lifecycle::on_compose`. Defaults to
  /// NoopUiPort so pre-compose writes and headless hosts are silent no-ops.
  priv mut ui : &@posoco.UiPort
  priv mut entries : Array[TodoItem]
  priv mut rev : Int
}

///|
/// Create an empty todo list at revision 0.
///
/// # Example
/// ```mbt check
/// async test "todo_write round-trips through todo_read" {
///   let todos = TodoList::TodoList()
///   let write : @posoco.ToolCall = @posoco.ToolCall::{
///     call_id: @posoco.CallId::unchecked("c1"),
///     name: @posoco.ToolName::unchecked("todo_write"),
///     arguments: Json::object({
///       "todos": Json::array([
///         Json::object({
///           "content": Json::string("Survey the code"),
///           "status": Json::string("completed"),
///         }),
///         Json::object({
///           "content": Json::string("Patch the parser"),
///           "status": Json::string("in_progress"),
///         }),
///       ]),
///     }),
///   }
///   match todos.execute("todo_write", write) {
///     @posoco.ToolOutcome::Success(..) => ()
///     _ => fail("expected Success")
///   }
///   let read : @posoco.ToolCall = @posoco.ToolCall::{
///     call_id: @posoco.CallId::unchecked("c2"),
///     name: @posoco.ToolName::unchecked("todo_read"),
///     arguments: Json::object(Map::from_array([])),
///   }
///   match todos.execute("todo_read", read) {
///     @posoco.ToolOutcome::Success(content~, ..) =>
///       assert_true(content.contains("Patch the parser"))
///     _ => fail("expected Success")
///   }
/// }
/// ```
pub fn TodoList::TodoList() -> TodoList {
  {
    ui: @posoco.NoopUiPort::NoopUiPort() as &@posoco.UiPort,
    entries: [],
    rev: 0,
  }
}

///|
/// Snapshot of the current list, in list order.
pub fn TodoList::items(self : TodoList) -> Array[TodoItem] {
  self.entries.copy()
}

///|
/// Monotonic write counter: bumps once per accepted `todo_write`, never on
/// rejected or read-only calls.
pub fn TodoList::revision(self : TodoList) -> Int {
  self.rev
}

///|
/// The render declaration: project the current list into one Widget render
/// intent and push it through the composed UI. The same key replaces the
/// previous intent, so every write refreshes a single host-side region; the
/// host decides whether and where to mount it.
fn TodoList::push_render(self : TodoList) -> Unit {
  self.ui.render(@posoco.UiRender::{
    slot: @posoco.UiSlot::Widget,
    key: "todo",
    title: Some("Todos"),
    body: @posoco.UiBody::Lines(render_lines(self.entries)),
    ttl_ms: None,
  })
}

///|
/// Parse and validate a `todo_write` argument payload. Every failure
/// carries a precise, model-correctable reason.
fn parse_todos(arguments : Json) -> Result[Array[TodoItem], String] {
  match arguments {
    Object(fields) =>
      match fields.get("todos") {
        Some(Array(entries)) => parse_entries(entries)
        Some(_) => Err("'todos' must be an array of {content, status} objects")
        None => Err("missing 'todos' argument")
      }
    _ => Err("arguments must be a JSON object with a 'todos' array")
  }
}

///|
fn parse_entries(entries : Array[Json]) -> Result[Array[TodoItem], String] {
  if entries.length() > MAX_TODOS {
    return Err(
      "todo list is limited to \{MAX_TODOS} entries (got \{entries.length()}) — split the work",
    )
  }
  let items : Array[TodoItem] = []
  for i, entry in entries {
    match entry {
      Object(fields) => {
        let content = match fields.get("content") {
          Some(String(text)) =>
            if text.trim().length() == 0 {
              return Err("todos[\{i}].content must be a non-empty string")
            } else {
              text
            }
          Some(_) => return Err("todos[\{i}].content must be a string")
          None => return Err("todos[\{i}] is missing 'content'")
        }
        let status = match fields.get("status") {
          Some(String(text)) =>
            match TodoStatus::parse(text) {
              Some(parsed) => parsed
              None =>
                return Err(
                  "todos[\{i}].status must be one of pending | in_progress | completed (got '\{text}')",
                )
            }
          Some(_) => return Err("todos[\{i}].status must be a string")
          None => return Err("todos[\{i}] is missing 'status'")
        }
        items.push({ content, status, })
      }
      _ =>
        return Err("todos[\{i}] must be an object with 'content' and 'status'")
    }
  }
  let in_progress = count_status(items, InProgress)
  if in_progress > 1 {
    return Err(
      "at most one task may be in_progress (got \{in_progress}) — mark the others pending or completed",
    )
  }
  Ok(items)
}
