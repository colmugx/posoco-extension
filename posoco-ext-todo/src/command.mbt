///|
/// The `/todo` command: show the current list to the user. Pure read —
/// it never mutates state or bumps the revision.

///|
pub impl @posoco.CommandPort for TodoList with fn commands(_self : TodoList) -> Array[
  @posoco.CommandDef,
] {
  [
    @posoco.CommandDef::{
      id: "todo",
      label: "Todo List",
      description: "Show the current task list",
      category: "todo",
      ctype: @posoco.CommandType::Action,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
pub impl @posoco.CommandPort for TodoList with fn invoke(
  self : TodoList,
  id : String,
  _args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  if id != "todo" {
    raise @posoco.CommandError::NotFound(id)
  }
  let feedback = if self.entries.is_empty() {
    "Todo list is empty."
  } else {
    "Todo list (revision \{self.rev}, \{summary_line(self.entries)}):\n\{render_todos(self.entries)}"
  }
  @posoco.CommandOutcome::Success(
    feedback~,
    structured=Some(structured_state(self.entries, self.rev)),
    ui_hint=None,
  )
}
