///|
/// The todo tools:
///
/// - `todo_write`: Cursor-shaped write of the checklist. Every item carries a
///   stable `id`; `merge=true` folds the call into the existing list by id
///   (partial updates — send only `id` + `status` to flip a status — and
///   appends unknown ids), otherwise the call replaces the whole list and an
///   empty array clears it. Validation failures (shape, the status/priority
///   enums, duplicate ids, missing content for new items, the MAX_TODOS
///   limit) return to the model as `ToolReportedError`, never as raises.
///   "At most one in_progress" is guidance in the description and the system
///   prompt, not a hard check — parallel work is a legitimate list state.
///   The result text is the checklist with item ids so the model can address
///   later merges; `structured` carries the machine-readable summary.
/// - `todo_read`: the current list with ids, or an orientation hint when
///   empty.
///
/// Both tools are `Sequential`: they read and write one shared list, so two
/// calls sharing a parallel wave would otherwise race.

///|
fn write_tool_def() -> @posoco.ToolDef {
  @posoco.ToolDef(
    name=@posoco.ToolName::unchecked("todo_write"),
    description="Create and manage a structured task list for the current session; the user sees it live. Use it for any task with three or more steps; skip it for single, straightforward actions. Every todo carries a stable id: merge=true folds the call into the existing list by id (send just id + status to flip a status; unknown ids are appended), while an omitted or false merge replaces the whole list — an empty array clears it. Mark items completed the moment they finish, cancelled when you skip them, and keep at most one in_progress. The result echoes the list with item ids for later merges.",
    input_schema=Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "merge": Json::object({
          "type": Json::string("boolean"),
          "description": Json::string(
            "Optional, default false. true merges the todos into the existing list by id; false replaces the list.",
          ),
        }),
        "todos": Json::object({
          "type": Json::string("array"),
          "description": Json::string(
            "Complete task list in execution order (max \{MAX_TODOS}) when merge is false; only the items to update or append when merge is true.",
          ),
          "items": Json::object({
            "type": Json::string("object"),
            "properties": Json::object({
              "id": Json::object({
                "type": Json::string("string"),
                "description": Json::string(
                  "Stable identifier, e.g. 'run-tests'; reuse it in later merge=true calls.",
                ),
              }),
              "content": Json::object({
                "type": Json::string("string"),
                "description": Json::string(
                  "Short imperative task text, e.g. 'Run the test suite'. Required unless merging an id that is already in the list.",
                ),
              }),
              "status": Json::object({
                "type": Json::string("string"),
                "enum": Json::array([
                  Json::string("pending"),
                  Json::string("in_progress"),
                  Json::string("completed"),
                  Json::string("cancelled"),
                ]),
              }),
              "priority": Json::object({
                "type": Json::string("string"),
                "enum": Json::array([
                  Json::string("high"),
                  Json::string("medium"),
                  Json::string("low"),
                ]),
                "description": Json::string("Optional; defaults to medium."),
              }),
            }),
            "required": Json::array([Json::string("id"), Json::string("status")]),
          }),
        }),
      }),
      "required": Json::array([Json::string("todos")]),
    }),
    owner=@posoco.OwnerId::unchecked("posoco_ext_todo"),
    policy=@posoco.ExecutionPolicy::Sequential,
    provenance=Some("posoco_ext_todo"),
  )
}

///|
fn read_tool_def() -> @posoco.ToolDef {
  @posoco.ToolDef(
    name=@posoco.ToolName::unchecked("todo_read"),
    description="Read the current task list with its item ids. Use it to reorient after context loss or before deciding the next step; the list is empty until you call todo_write.",
    input_schema=Json::object({
      "type": Json::string("object"),
      "properties": Json::object(Map::from_array([])),
    }),
    owner=@posoco.OwnerId::unchecked("posoco_ext_todo"),
    policy=@posoco.ExecutionPolicy::Sequential,
    provenance=Some("posoco_ext_todo"),
  )
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
fn reported(name : String, reason : String) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::ToolReportedError(
    content="\{name}: \{reason}",
    structured=None,
  )
}

///|
fn TodoList::execute_write(
  self : TodoList,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome {
  match parse_write(call.arguments) {
    Err(reason) => reported(name, reason)
    Ok(write) =>
      match self.commit_write(write) {
        Err(reason) => reported(name, reason)
        Ok(_) => {
          self.push_render()
          @posoco.ToolOutcome::Success(
            content="Todo list saved (revision \{self.rev}):\n\{render_todos_for_model(self.entries)}",
            structured=Some(structured_state(self.entries, self.rev)),
          )
        }
      }
  }
}

///|
fn TodoList::execute_read(
  self : TodoList,
  _name : String,
) -> @posoco.ToolOutcome {
  let content = if self.entries.is_empty() {
    "Todo list is empty. Use todo_write to break a multi-step task into a checklist (at most one item in_progress); single straightforward actions need no list."
  } else {
    "Current todo list (revision \{self.rev}):\n\{render_todos_for_model(self.entries)}"
  }
  @posoco.ToolOutcome::Success(
    content~,
    structured=Some(structured_state(self.entries, self.rev)),
  )
}

///|
pub impl @posoco.ToolProvider for TodoList with fn execute(
  self : TodoList,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  let call : @posoco.ToolCall = {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  }
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
