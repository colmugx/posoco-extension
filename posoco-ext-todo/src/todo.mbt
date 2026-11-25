///|
/// posoco-ext-todo — a Cursor-style `todo_write` task list extension for Posoco.
///
/// The model maintains a structured checklist through the `todo_write` /
/// `todo_read` tools. `todo_write` follows Cursor's shape: every item carries
/// a stable `id`; `merge=true` folds the call into the existing list by id
/// (partial updates, unknown ids appended), otherwise the call replaces the
/// whole list. Hosts learn about the list through render intents: every
/// successful write pushes one `UiPort::render` Widget intent (key `"todo"`)
/// through the composed UI, and the `/todo` command shows the list to the
/// user. The extension is a UI consumer, not a UI provider (`requires:
/// [Capability::Ui]`, empty `ui` manifest slot).
///
/// State is an in-process session list with a monotonic revision counter —
/// restarting the process starts from an empty list; this extension does not
/// persist the list to disk.
///
/// Usage:
///   let todos = TodoList::TodoList()
///   let agent = Agent(exts=[todos], config=...)

///|
/// Lifecycle state of one task. `Cancelled` keeps a skipped step visible in
/// the list instead of dropping it.
#derive(Eq, Debug)
pub(all) enum TodoStatus {
  Pending
  InProgress
  Completed
  Cancelled
}

///|
pub extend TodoStatus with Eq::{not_equal, equal}

///|
pub extend TodoStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Wire/display spelling of the status — also the `todo_write` enum values.
pub impl Show for TodoStatus with fn to_string(self) -> String {
  match self {
    Pending => "pending"
    InProgress => "in_progress"
    Completed => "completed"
    Cancelled => "cancelled"
  }
}

///|
pub extend TodoStatus with Show::{output}

///|
fn TodoStatus::parse(text : String) -> TodoStatus? {
  match text {
    "pending" => Some(Pending)
    "in_progress" => Some(InProgress)
    "completed" => Some(Completed)
    "cancelled" => Some(Cancelled)
    _ => None
  }
}

///|
/// Cursor-style priority of one task; `Medium` when the model omits it.
#derive(Eq, Debug)
pub(all) enum TodoPriority {
  High
  Medium
  Low
}

///|
pub extend TodoPriority with Eq::{not_equal, equal}

///|
pub extend TodoPriority with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for TodoPriority with fn to_string(self) -> String {
  match self {
    High => "high"
    Medium => "medium"
    Low => "low"
  }
}

///|
pub extend TodoPriority with Show::{output}

///|
fn TodoPriority::parse(text : String) -> TodoPriority? {
  match text {
    "high" => Some(High)
    "medium" => Some(Medium)
    "low" => Some(Low)
    _ => None
  }
}

///|
/// One checklist entry: a stable id for `merge` updates, short imperative
/// content, lifecycle status, and priority.
#derive(Eq, Debug)
pub(all) struct TodoItem {
  id : String
  content : String
  status : TodoStatus
  priority : TodoPriority
}

///|
pub extend TodoItem with Eq::{not_equal, equal}

///|
pub extend TodoItem with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Upper bound on list length accepted by `todo_write`.
pub const MAX_TODOS : Int32 = 50

///|
fn status_marker(status : TodoStatus) -> String {
  match status {
    Completed => "[x]"
    InProgress => "[>]"
    Pending => "[ ]"
    Cancelled => "[-]"
  }
}

///|
fn count_status(items : Array[TodoItem], status : TodoStatus) -> Int32 {
  items.iter().filter(item => item.status == status).count()
}

///|
/// The checklist body: one line per task, in list order. `with_ids` appends
/// the item id so the model can address items in later `merge` writes; the
/// user-facing views leave it out.
fn render_lines(items : Array[TodoItem], with_ids : Bool) -> Array[String] {
  let lines : Array[String] = []
  for i, item in items {
    let id = if with_ids { " (id=\{item.id})" } else { "" }
    lines.push("\{status_marker(item.status)} \{i + 1}. \{item.content}\{id}")
  }
  lines
}

///|
fn render_list(items : Array[TodoItem], with_ids : Bool) -> String {
  if items.is_empty() {
    return "(no todos)"
  }
  let done = count_status(items, Completed)
  let lines : Array[String] = ["\{done}/\{items.length()} done"]
  for line in render_lines(items, with_ids) {
    lines.push(line)
  }
  lines.join("\n")
}

///|
/// User-facing text projection: a progress header, then the checklist lines.
/// The view behind the `/todo` command.
pub fn render_todos(items : Array[TodoItem]) -> String {
  render_list(items, false)
}

///|
/// Model-facing projection: the same list with item ids, so a later
/// `merge=true` write can name the items it updates.
fn render_todos_for_model(items : Array[TodoItem]) -> String {
  render_list(items, true)
}

///|
/// One-line row text, e.g. "4 tasks: 1 completed, 1 in progress, 1 pending,
/// 1 cancelled".
fn summary_line(items : Array[TodoItem]) -> String {
  if items.is_empty() {
    return "no todos"
  }
  let completed = count_status(items, Completed)
  let in_progress = count_status(items, InProgress)
  let pending = count_status(items, Pending)
  let cancelled = count_status(items, Cancelled)
  "\{items.length()} tasks: \{completed} completed, \{in_progress} in progress, \{pending} pending, \{cancelled} cancelled"
}

///|
/// Structured payload carried by tool results and command outcomes. The
/// reserved `summary` field holds the one-line row text a UI shows; `items`
/// mirrors the list for machine-readable observers.
fn structured_state(items : Array[TodoItem], revision : Int32) -> Json {
  Json::object(
    Map::from_array([
      ("summary", Json::string(summary_line(items))),
      ("revision", Json::number(revision.to_double())),
      ("total", Json::number(items.length().to_double())),
      ("completed", Json::number(count_status(items, Completed).to_double())),
      ("in_progress", Json::number(count_status(items, InProgress).to_double())),
      ("pending", Json::number(count_status(items, Pending).to_double())),
      ("cancelled", Json::number(count_status(items, Cancelled).to_double())),
      (
        "items",
        Json::array(
          items.map(item => {
            Json::object(
              Map::from_array([
                ("id", Json::string(item.id)),
                ("content", Json::string(item.content)),
                ("status", Json::string(item.status.to_string())),
                ("priority", Json::string(item.priority.to_string())),
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
  priv mut rev : Int32
}

///|
/// Create an empty todo list at revision 0.
///
/// # Example
/// Not checked: the snippet builds its tool-call context with the testkit
/// helper `@tk.tk_tool_call_ctx` (`posoco/devkit/testkit`), which only test
/// packages may import. `posoco_ext_todo_wbtest.mbt` runs the same round-trip.
/// ```mbt nocheck
/// async test "todo_write round-trips through todo_read" {
///   let todos = @posoco-ext-todo.TodoList::TodoList()
///   let write = @tk.tk_tool_call_ctx(
///     name="todo_write",
///     arguments=Json::object({
///       "todos": Json::array([
///         Json::object({
///           "id": Json::string("survey"),
///           "content": Json::string("Survey the code"),
///           "status": Json::string("completed"),
///         }),
///         Json::object({
///           "id": Json::string("patch"),
///           "content": Json::string("Patch the parser"),
///           "status": Json::string("in_progress"),
///         }),
///       ]),
///     }),
///   )
///   match todos.execute(write) {
///     @posoco.ToolOutcome::Success(..) => ()
///     _ => fail("expected Success")
///   }
///   let read = @tk.tk_tool_call_ctx(name="todo_read")
///   match todos.execute(read) {
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
pub fn TodoList::revision(self : TodoList) -> Int32 {
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
    body: @posoco.UiBody::Lines(render_lines(self.entries, false)),
    ttl_ms: None,
  })
}

///|
/// One entry of a `todo_write` call, after shape validation. `content` and
/// `priority` are optional so a `merge` update can send just `id` + `status`.
priv struct TodoUpdate {
  id : String
  content : String?
  status : TodoStatus
  priority : TodoPriority?
}

///|
/// A validated `todo_write` call: the write mode plus its entries.
priv struct TodoWrite {
  merge : Bool
  updates : Array[TodoUpdate]
}

///|
fn TodoUpdate::has_content(self : TodoUpdate) -> Bool {
  match self.content {
    Some(text) => text.trim().length() > 0
    None => false
  }
}

///|
/// The entry as a full item. Only valid once `has_content` has been checked.
fn TodoUpdate::to_item(self : TodoUpdate) -> TodoItem {
  {
    id: self.id,
    content: self.content.unwrap(),
    status: self.status,
    priority: self.priority.unwrap_or(Medium),
  }
}

///|
/// Partial update of an existing item: content and priority stay unless the
/// call supplies them; status is always applied.
fn TodoUpdate::apply_to(self : TodoUpdate, current : TodoItem) -> TodoItem {
  {
    id: current.id,
    content: if self.has_content() {
      self.content.unwrap()
    } else {
      current.content
    },
    status: self.status,
    priority: self.priority.unwrap_or(current.priority),
  }
}

///|
/// Replace mode requires content on every entry; merge mode leaves it
/// optional because an existing item keeps its text.
fn require_content(content : String?, i : Int32) -> Result[Unit, String] {
  match content {
    Some(text) =>
      if text.trim().length() == 0 {
        Err("todos[\{i}].content must be a non-empty string")
      } else {
        Ok(())
      }
    None => Err("todos[\{i}] is missing 'content'")
  }
}

///|
fn has_id(updates : Array[TodoUpdate], id : String) -> Bool {
  for update in updates {
    if update.id == id {
      return true
    }
  }
  false
}

///|
fn parse_updates(
  entries : Array[Json],
  merge : Bool,
) -> Result[Array[TodoUpdate], String] {
  let updates : Array[TodoUpdate] = []
  for i, entry in entries {
    match entry {
      Object(fields) => {
        let id = match fields.get("id") {
          Some(String(text)) =>
            if text.trim().length() == 0 {
              return Err("todos[\{i}].id must be a non-empty string")
            } else {
              text
            }
          Some(_) => return Err("todos[\{i}].id must be a string")
          None => return Err("todos[\{i}] is missing 'id'")
        }
        if has_id(updates, id) {
          return Err(
            "todos[\{i}].id '\{id}' is duplicated in this call — each item needs a unique id",
          )
        }
        let content = match fields.get("content") {
          None => None
          Some(String(text)) => Some(text)
          Some(_) => return Err("todos[\{i}].content must be a string")
        }
        if !merge {
          match require_content(content, i) {
            Err(reason) => return Err(reason)
            Ok(_) => ()
          }
        }
        let status = match fields.get("status") {
          Some(String(text)) =>
            match TodoStatus::parse(text) {
              Some(parsed) => parsed
              None =>
                return Err(
                  "todos[\{i}].status must be one of pending | in_progress | completed | cancelled (got '\{text}')",
                )
            }
          Some(_) => return Err("todos[\{i}].status must be a string")
          None => return Err("todos[\{i}] is missing 'status'")
        }
        let priority = match fields.get("priority") {
          None => None
          Some(String(text)) =>
            match TodoPriority::parse(text) {
              Some(parsed) => Some(parsed)
              None =>
                return Err(
                  "todos[\{i}].priority must be one of high | medium | low (got '\{text}')",
                )
            }
          Some(_) => return Err("todos[\{i}].priority must be a string")
        }
        updates.push({ id, content, status, priority, })
      }
      _ => return Err("todos[\{i}] must be an object with 'id' and 'status'")
    }
  }
  Ok(updates)
}

///|
/// Parse and validate a `todo_write` argument payload: the `merge` flag and
/// every entry's `id`, `status`, optional `content` and `priority`. In
/// replace mode `content` is required for each entry; duplicate ids are
/// rejected in both modes. Every failure carries a precise, model-correctable
/// reason.
fn parse_write(arguments : Json) -> Result[TodoWrite, String] {
  match arguments {
    Object(fields) =>
      match fields.get("todos") {
        Some(Array(entries)) => {
          let merge = match fields.get("merge") {
            None => false
            Some(True) => true
            Some(False) => false
            Some(_) => return Err("'merge' must be a boolean")
          }
          parse_updates(entries, merge).map(updates => { merge, updates, })
        }
        Some(_) =>
          Err("'todos' must be an array of {id, content, status} objects")
        None => Err("missing 'todos' argument")
      }
    _ => Err("arguments must be a JSON object with a 'todos' array")
  }
}

///|
fn position_of(items : Array[TodoItem], id : String) -> Int32 {
  for i, item in items {
    if item.id == id {
      return i
    }
  }
  -1
}

///|
/// Fold a validated write into the list it would produce, without touching
/// extension state. Merge keeps existing items in place (content optional,
/// `status` always applied, `priority` kept unless given) and appends unknown
/// ids; replace yields the updates as a fresh list.
fn fold_write(
  current : Array[TodoItem],
  write : TodoWrite,
) -> Result[Array[TodoItem], String] {
  if !write.merge {
    return Ok(write.updates.map(update => update.to_item()))
  }
  let merged = current.copy()
  for i, update in write.updates {
    let at = position_of(merged, update.id)
    if at >= 0 {
      merged[at] = update.apply_to(merged[at])
    } else if update.has_content() {
      merged.push(update.to_item())
    } else {
      return Err(
        "todos[\{i}]: content is required for new id '\{update.id}' — only items already in the list may omit it",
      )
    }
  }
  Ok(merged)
}

///|
/// Commit a validated write: fold it, enforce the size limit on the result,
/// then swap the list and bump the revision. A rejected write leaves both the
/// list and the revision untouched.
fn TodoList::commit_write(
  self : TodoList,
  write : TodoWrite,
) -> Result[Unit, String] {
  let candidate = match fold_write(self.entries, write) {
    Ok(candidate) => candidate
    Err(reason) => return Err(reason)
  }
  if candidate.length() > MAX_TODOS {
    return Err(
      "todo list is limited to \{MAX_TODOS} entries (got \{candidate.length()}) — split the work",
    )
  }
  self.entries = candidate
  self.rev = self.rev + 1
  Ok(())
}
