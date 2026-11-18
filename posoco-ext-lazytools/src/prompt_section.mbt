///|
/// The resident discoverability surface: a stable system-prompt section naming
/// every deferred owner and its host-authored capability hint. Full schemas
/// stay behind `tool_list` and remain reusable from conversation history once
/// fetched.
///
/// The section is frozen by Posoco after the first model call and cannot
/// enumerate live tools (a group may not have published yet), so it carries
/// owner-level hints only — that is what keeps prefix caching intact across
/// connection and toolkit churn.

///|
/// Keep resident hints deliberately small: this text is paid on every model
/// request, while the complete schema is available on demand.
const PROMPT_HINT_CAP = 96

///|
/// One compact bullet per declared group in declaration order. The display id
/// strips the packaging prefix; the hint is a single capped line.
fn LazyTools::catalog_bullets(self : LazyTools) -> String {
  let lines : Array[String] = []
  for group in self.groups {
    let id = display_id(group.owner)
    let hint = truncate_oneline(group.hint, PROMPT_HINT_CAP)
    if hint == "" {
      lines.push("- \{id}")
    } else {
      lines.push("- \{id}: \{hint}")
    }
  }
  if lines.is_empty() {
    "(no deferred groups)"
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

///|
pub extend LazyTools with @posoco.SystemPromptContributor::{system_prompt}
