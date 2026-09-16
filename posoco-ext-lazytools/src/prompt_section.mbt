///|
/// The resident discoverability surface: a system-prompt section listing
/// every folded extension group with its tools (names + descriptions), so
/// the model knows what the fold hides without loading every schema. Schemas
/// are fetched on demand via `tool_list` and then remain reusable from the
/// conversation history.

///|
/// Max description characters shown per tool in the resident section.
const PROMPT_DESC_CAP = 120

///|
/// One bullet per extension group in first-seen declaration order: the
/// display id (manifest id without packaging prefix) followed by its tools,
/// names and truncated descriptions auto-concatenated. Extensions whose
/// tools lack descriptions show bare names; tool descriptions are part of
/// the deferred-extension contract.
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
/// Resident deferral section. English is the product prompt language. Keep
/// all reuse guidance here because Posoco freezes SystemPromptContributors
/// after the first model call, preserving the provider's prompt prefix.
pub impl @posoco.SystemPromptContributor for LazyTools with fn system_prompt(
  self : LazyTools,
) -> String {
  (
    $|## Deferred tools
    $|
    $|The following tool groups are folded to keep this conversation's context small: the tools exist, but their schemas are not loaded up front. Before calling a folded tool, use a schema that is already present in this conversation from an earlier `tool_list` result when one is available. Otherwise, you MUST look it up with `tool_list` (optionally with a keyword). Then call it with `tool_execute`. Do not repeat `tool_list` only to rediscover a schema already visible in the conversation history. Folded groups:
    $|\{self.catalog_bullets()}
  )
}
