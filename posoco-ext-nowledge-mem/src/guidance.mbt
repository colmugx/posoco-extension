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
  "## Nowledge Mem\nRecall prior decisions/preferences with memory_search; use thread_search for past conversation history. Search before saving to avoid duplicates; update close matches instead of adding near-copies. Reuse the session's injected <nmem-context> before re-fetching. Threads from this host use source_app=\{source_app}."
}
