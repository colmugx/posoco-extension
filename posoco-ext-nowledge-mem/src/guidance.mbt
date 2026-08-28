///|
/// Stable extension id used in manifests and diagnostics.
pub const NMEM_EXTENSION_ID : String = "posoco_ext_nowledge_mem"

///|
/// Host label for user-visible copy, derived from `source_app`: the first
/// ASCII letter uppercased ("cetas" → "Cetas", "demo" → "Demo"); everything
/// else passes through unchanged.
fn host_label(source_app : String) -> String {
  let builder = StringBuilder()
  let mut first = true
  for ch in source_app {
    builder.write_char(
      if first {
        first = false
        ch.to_ascii_uppercase()
      } else {
        ch
      },
    )
  }
  builder.to_string()
}

///|
/// Startup guidance appended to the system prompt on every turn start
/// (upstream startupGuidance): when to search, when to save, how to route
/// between memories and threads, and the provenance this host's synced
/// threads carry. `source_app` is the host product identity; the host label
/// in the copy derives from it via `host_label`.
fn startup_guidance(source_app : String) -> String {
  let guidance =
    $| ## Nowledge Mem Guidance
    $| You are connected to Nowledge Mem, a persistent cross-tool memory:
    $| - **Distilled memories** are reusable knowledge (decisions, preferences, workflows, project facts).
    $| - **Threads** are past conversation histories, including sessions from other tools.
    $|
    $| ### When to search
    $| - Before answering questions that prior sessions may have settled (decisions, preferences, setup steps, past errors), search memories first. The working-memory briefing is injected once, at the session's first turn — after that, searching is the only recall path.
    $| - Search when the topic switches mid-session and earlier decisions or setup details may apply.
    $| - Search when the user names a person, project, or past decision, or refers to earlier work ("remember when", "as we discussed", "last time", "还记得吗", "之前说过") that you cannot see in this transcript; search threads for the conversation history.
    $| - Search before assuming project conventions; a recorded decision beats a guess.
    $| - Search beats guessing: a short retrieval is cheaper than re-deriving or contradicting a recorded decision.
    $|
    $| ### When to save
    $| - Save a memory when the user states a durable preference, a decision is made, or a workflow is established that future sessions should honor.
    $| - Search before saving to avoid duplicates; if a close match exists, update it instead of adding a near-copy.
    $| - Prefer fewer, high-quality memories over logging every exchange; do not save transient details, secrets, or one-off facts.
    $|
    $| ### Routing
    $| - Use memory search for distilled knowledge; use thread search for conversation history and context.
    $| - Keep working-session state in the current conversation; only promote it to memory once it is settled and reusable.
    $| - If the user asks something like 'What should I do today?' or 'What should I do now?' or "今天做点什么好", you SHOULD to refer to `# Working Memory` first. If the information here is sufficient, rely on it directly and avoid calling external tools (as the tool results are likely identical).
    $|
    $| ### Provenance
    $| - Threads synced by this \{host_label(source_app)} agent are recorded under source app "\{source_app}"; threads from other tools carry their own source app.

  guidance
}
