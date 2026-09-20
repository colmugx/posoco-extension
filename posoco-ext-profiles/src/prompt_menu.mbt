///|
/// The `## Profiles` system-prompt section: the resident menu the model
/// picks `activate_profile` arguments from (one content, two uses with the
/// manifest description — §2).

///|
/// Description truncation cap for one menu row, in characters. Adjustable:
/// long author descriptions are cut so a row stays one line (§10).
const MENU_DESCRIPTION_CAP = 160

///|
/// The fixed one-sentence description of the builtin `all` preset (§2):
/// profiles are never empty — when no profile matches, `all` is the
/// structurally guaranteed fallback.
const ALL_PROFILE_DESCRIPTION = "covers every deferred extension; activate when no specific profile matches"

///|
/// One menu row: `id: description`, plus the dangling suffix when the
/// manifest references uncomposed extensions (Q13).
fn menu_row(entry : ProfileEntry) -> String {
  let mut row = "\{entry.id}: \{truncate_menu_description(entry.description)}"
  if !entry.dangling.is_empty() {
    row = "\{row} (dangling: \{entry.dangling.join(", ")})"
  }
  row
}

///|
/// Cut a description to MENU_DESCRIPTION_CAP characters, appending an
/// ASCII ellipsis only when actually cut.
fn truncate_menu_description(description : String) -> String {
  if description.length() <= MENU_DESCRIPTION_CAP {
    description
  } else {
    description[0:MENU_DESCRIPTION_CAP].to_owned() + "..."
  }
}

///|
/// The system-prompt menu section.
///
/// Byte-stability is contractual (§7.2): the content depends only on
/// composition-time build inputs. Profiles saved at runtime enter the
/// in-memory catalog at once — activate_profile accepts them and the
/// unknown-id enumeration lists them (Q19) — but they deliberately do NOT
/// appear here: the menu, like the deep-deferred views, stays frozen for
/// the composition's lifetime so the prompt-cache prefix never breaks. The
/// full benefit (a menu row of its own plus deferred manuals) is realized
/// at the next composition.
pub impl @posoco.SystemPromptContributor for Profiles with fn system_prompt(
  self : Profiles,
) -> String {
  let lines : Array[String] = []
  lines.push("## Profiles")
  lines.push("")
  lines.push(
    "Profiles are named intent packages that bundle related extensions behind one activation. Pick the entry matching the user's task and activate it with the `activate_profile` tool; when no profile matches, activate `all`.",
  )
  for entry in self.catalog {
    lines.push("- \{menu_row(entry)}")
  }
  lines.join("\n")
}
