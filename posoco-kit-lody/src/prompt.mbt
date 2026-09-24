// prompt.mbt — the delegation prompt section contributed to the system prompt
// when a lody host is detected. Pure text; the host decides whether and where
// to mount it (e.g. via a SystemPromptContributor at the composition layer).

///|
/// Prompt section describing lody delegated-task semantics for the agent.
pub fn prompt_section() -> String {
  (
    #|## Delegated tasks (lody)
    #|
    #|This host can delegate self-contained work to parallel agent sessions.
    #|
    #|- Delegate long independent work through the delegated-task tools
    #|  (prefixed `lody_`) instead of doing it inline; each delegation gets
    #|  one stable task id — keep using the same id to chat with, poll, or
    #|  cancel that task.
    #|- Delegated tasks report state in two places: the `task` envelope on
    #|  tool-call updates (pending / in_progress / completed / failed) and
    #|  subagent listings (running / completed / failed / timed_out / killed
    #|  / lost). Those fields are the only authority for task state; never
    #|  infer it from a tool's human-readable title.
    #|- failed, timed_out, and killed are terminal: read the task's error or
    #|  output, then decide whether to re-delegate with a narrower prompt.
    #|
  )
}
