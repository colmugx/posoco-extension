///|
/// The resident discoverability surface: a system-prompt section listing
/// every folded extension group with its tools (names + descriptions), so
/// the model knows what the fold hides without loading any schema. Schemas
/// stay on demand via `tool_list`.

///|
/// Max description characters shown per tool in the resident section.
const PROMPT_DESC_CAP = 120

///|
/// One bullet per extension group in first-seen declaration order: the
/// display id (manifest id without packaging prefix) followed by its tools,
/// names and truncated descriptions auto-concatenated. Extensions whose
/// tools lack descriptions show bare names — from today on, tool
/// descriptions are part of the deferred-extension contract.
fn LazyTools::catalog_bullets(self : LazyTools) -> String {
  let lines : Array[String] = []
  for group in self.groups() {
    let tools = group.entries.map(fn(entry) {
      "\{entry.def.name.to_string()} — \{truncate_oneline(entry.def.description, PROMPT_DESC_CAP)}"
    })
    lines.push("- \{group.id}: \{tools.join("; ")}")
  }
  if lines.is_empty() {
    "(no folded tools)"
  } else {
    lines.join("\n")
  }
}

///|
/// Resident deferral section. English is the product prompt language; the
/// MUST directive tells the model to look up the fold before concluding a
/// task needs more tools.
pub impl @posoco.SystemPromptContributor for LazyTools with fn system_prompt(
  self : LazyTools,
) -> String {
  (
    $|## Deferred tools
    $|
    $|The following tool groups are folded to keep this conversation's context small: the tools exist, but their schemas are not loaded. When your task may need one of them, you MUST look them up with `tool_list` (optionally with a keyword) and then call the tool with `tool_execute`. Folded groups:
    $|\{self.catalog_bullets()}
  )
}
