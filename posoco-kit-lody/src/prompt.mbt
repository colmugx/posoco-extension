// prompt.mbt — the delegation prompt section contributed to the system prompt
// when a lody host is detected. Pure text; the host decides whether and where
// to mount it (e.g. via a SystemPromptContributor at the composition layer).

///|
/// Prompt section describing lody delegated-task semantics for the agent.
pub fn prompt_section() -> String {
  (
    #|## Delegated tasks (lody)
    #|Delegate long independent work with `lody_*` tools. Reuse one stable
    #|task id for chat/poll/cancel. Treat task/update status fields as
    #|authoritative; never infer state from titles. failed/timed_out/killed are
    #|terminal: inspect error/output, then re-delegate narrower work if needed.
  )
}
