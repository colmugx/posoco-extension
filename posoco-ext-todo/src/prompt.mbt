///|
/// Static usage guidance. Byte-stable by contract — no counts, session
/// state, or revision numbers — so the prompt cache never invalidates.
pub impl @posoco.SystemPromptContributor for TodoList with fn system_prompt(
  _self : TodoList,
) -> String {
  "Task list tools (todo_write, todo_read) maintain a visible checklist for the current session.\n" +
  "- For multi-step tasks (roughly three steps or more), write the plan with todo_write before starting work; skip it for single, straightforward actions.\n" +
  "- Keep exactly ONE task in_progress; mark a task completed the moment it is done, and add newly discovered steps as pending.\n" +
  "- todo_write replaces the whole list. Keep each content short and imperative — the list is shown to the user."
}
