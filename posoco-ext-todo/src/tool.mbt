///|
/// The todo tools:
///
/// - `todo_write`: full-replacement write of the checklist. Validated:
///   non-empty content, the status enum, the MAX_TODOS-entry limit, and
///   the mainstream constraint that AT MOST ONE task is `in_progress` —
///   the schema description spells the constraint out so the model knows
///   it before calling. Validation failures return to the model as
///   `ToolReportedError` (correctable, turn continues), never as raises.
///   The result text is the rendered checklist so the model confirms what
///   the user sees; `structured` carries the machine-readable summary.
/// - `todo_read`: the current list, or an orientation hint when empty.

///|
fn write_tool_def() -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked("todo_write"),
    description: "Write the structured task list for the current session, replacing any previous list. Use it to plan multi-step work (roughly three steps or more) before starting, and keep it current while working: exactly ONE task may be 'in_progress' at any time, mark tasks 'completed' the moment they finish, append newly discovered steps as 'pending'. Skip it for single, straightforward actions. Pass an empty array to clear the list.",
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "todos": Json::object({
          "type": Json::string("array"),
          "description": "The complete task list in execution order (max \{MAX_TODOS} entries); at most one entry may have status 'in_progress'.",
          "items": Json::object({
            "type": Json::string("object"),
            "properties": Json::object({
              "content": Json::object({
                "type": Json::string("string"),
                "description": "Short imperative task text, e.g. 'Run the test suite'",
              }),
              "status": Json::object({
                "type": Json::string("string"),
                "enum": Json::array([
                  Json::string("pending"),
                  Json::string("in_progress"),
                  Json::string("completed"),
                ]),
                "description": "pending = not started, in_progress = currently being worked on (at most one), completed = done",
              }),
            }),
            "required": Json::array([
              Json::string("content"),
              Json::string("status"),
            ]),
          }),
        }),
      }),
      "required": Json::array([Json::string("todos")]),
    }),
    owner: @posoco.OwnerId::unchecked("posoco_ext_todo"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_todo"),
  }
}

///|
fn read_tool_def() -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked("todo_read"),
    description: "Read the current task list. Use it to reorient after context loss or before deciding the next step; the list is empty until you call todo_write.",
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object(Map::from_array([])),
    }),
    owner: @posoco.OwnerId::unchecked("posoco_ext_todo"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_todo"),
  }
}

///|
/// Declare the todo tools. Owner/policy follow the ToolProvider contract —
/// the catalog builder derives ownership and pins the execution policy.
pub impl @posoco.ToolProvider for TodoList with fn list_tools(_self : TodoList) -> Array[
  @posoco.ToolDef,
] {
  [write_tool_def(), read_tool_def()]
}

///|
fn TodoList::execute_write(
  self : TodoList,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome {
  match parse_todos(call.arguments) {
    Err(reason) =>
      @posoco.ToolOutcome::ToolReportedError(
        content="\{name}: \{reason}",
        structured=None,
      )
    Ok(items) => {
      self.entries = items
      self.rev = self.rev + 1
      self.push_render()
      @posoco.ToolOutcome::Success(
        content="Todo list saved (revision \{self.rev}):\n\{render_todos(self.entries)}",
        structured=Some(structured_state(self.entries, self.rev)),
      )
    }
  }
}

///|
fn TodoList::execute_read(
  self : TodoList,
  _name : String,
) -> @posoco.ToolOutcome {
  let content = if self.entries.is_empty() {
    "Todo list is empty. Use todo_write to break a multi-step task into a checklist (at most one task in_progress); single straightforward actions need no list."
  } else {
    "Current todo list (revision \{self.rev}):\n\{render_todos(self.entries)}"
  }
  @posoco.ToolOutcome::Success(
    content~,
    structured=Some(structured_state(self.entries, self.rev)),
  )
}

///|
pub impl @posoco.ToolProvider for TodoList with fn execute(
  self : TodoList,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name == "todo_write" {
    return self.execute_write(name, call)
  }
  if name == "todo_read" {
    return self.execute_read(name)
  }
  raise @posoco.RuntimeError::UnknownTool(
    "posoco_ext_todo: unknown tool '\{name}'",
  )
}
