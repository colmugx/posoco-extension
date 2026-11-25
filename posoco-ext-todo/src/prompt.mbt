///|
/// Static usage guidance. Byte-stable by contract — no counts, session
/// state, or revision numbers — so the prompt cache never invalidates.
pub impl @posoco.SystemPromptContributor for TodoList with fn system_prompt(
  _self : TodoList,
) -> String {
  "Task list tools (todo_write, todo_read) maintain a visible checklist for the current session; the user sees it live.\n" +
  "- For multi-step tasks (roughly three steps or more), write the plan with todo_write before starting work; skip it for single, straightforward actions.\n" +
  "- Give every item a short stable id. Later updates set merge=true and send only id + status to flip a status; a call without merge replaces the whole list.\n" +
  "- Mark a task completed the moment it is done and cancelled when you skip it; keep at most one task in_progress and add newly discovered steps as pending.\n" +
  "- Keep each content short and imperative — the list is shown to the user."
}
