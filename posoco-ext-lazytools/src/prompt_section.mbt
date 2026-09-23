///|
/// The resident discoverability surface: a stable system-prompt section that
/// names every folded extension group and gives each tool a short capability
/// hint. Full schemas stay deferred to `tool_list` and remain reusable from
/// conversation history once fetched.

///|
/// Keep resident capability hints deliberately small: this text is paid on
/// every model request, while the complete schema is available on demand.
const PROMPT_DESC_CAP = 48

///|
/// One compact bullet per extension group in first-seen declaration order.
/// The display id strips the packaging prefix; each tool keeps only a short,
/// single-line description so discovery remains useful without carrying the
/// full ToolDef prose in the resident prompt.
fn LazyTools::catalog_bullets(self : LazyTools) -> String {
  let lines : Array[String] = []
  for group in self.groups() {
    let tools = group.entries.map(fn(entry) {
      let name = entry.def.name.to_string()
      let description = truncate_oneline(entry.def.description, PROMPT_DESC_CAP)
      if description == "" {
        name
      } else {
        "\{name} — \{description}"
      }
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
/// Resident deferral guidance. Posoco freezes SystemPromptContributors after
/// the first model call, so keep this wording short and stable for prefix
/// caching. Schemas already present in history should be reused directly.
pub impl @posoco.SystemPromptContributor for LazyTools with fn system_prompt(
  self : LazyTools,
) -> String {
  (
    $|## Deferred tools
    $|Reuse a schema already shown by `tool_list`; otherwise call `tool_list` (optionally with `keyword`), then `tool_execute`. Do not rediscover schemas already in history.
    $|\{self.catalog_bullets()}
  )
}
