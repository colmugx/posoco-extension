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
/// Startup guidance appended to the system prompt on every turn start:
/// when to search, when to save, how to route
/// between memories and threads, and the provenance this host's synced
/// threads carry. `source_app` is the host product identity; the host label
/// in the copy derives from it via `host_label`.
fn startup_guidance(source_app : String) -> String {
  (
    $|## Nowledge Mem Guidance
    $|Distilled memories hold reusable decisions, preferences, workflows, and project facts; threads hold past conversations.
    $|
    $|### Search
    $|- Before answering something prior sessions may have settled, use memory_search. Opening memory is injected once per session; after that, search is the recall path.
    $|- Search again when the topic changes and earlier decisions/setup may apply.
    $|- If the user refers to a person, project, past decision, or earlier work not visible here, use thread_search for conversation history.
    $|- Search before assuming project conventions; recorded decisions beat guesses.
    $|- Prefer a short retrieval to re-deriving or contradicting remembered facts.
    $|
    $|### Save
    $|- Search before saving; update a close match instead of creating a near-duplicate.
    $|- Save settled, reusable knowledge; skip transient details, secrets, and one-off facts.
    $|
    $|### Routing
    $|- memory_search is for distilled knowledge; thread_search is for conversation history/context.
    $|- Keep working-session state in this conversation until it is settled and reusable.
    $|- Reuse an existing <nmem-context type="memory"> directly; do not re-fetch the same information. Check it first for "what should I do today/now" requests.
    $|
    $|### Provenance
    $|- Threads synced by this \{host_label(source_app)} agent use source_app="\{source_app}"; other tools keep their own source app.
  )
}
