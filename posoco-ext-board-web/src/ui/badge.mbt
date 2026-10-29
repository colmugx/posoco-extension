// Chips and badges.
//
// One pill vocabulary for metadata: the App maps its own tone classes onto
// these, so a chip can never be styled two different ways in two views.

///|
/// What a chip is saying, not how it looks. `Quiet` is neutral metadata,
/// `Pinned` is an explicit choice, `Running` is live work, `Warn` is a value
/// the host no longer offers.
pub(all) enum ChipTone {
  Quiet
  Pinned
  Running
  Success
  Warn
  Muted
}

///|
fn chip_variant(tone : ChipTone) -> @rui.BadgeVariant {
  match tone {
    // Quiet metadata still reads as a chip (hairline), while Muted is the
    // cancelled / not-run state that should recede.
    Quiet => @rui.BadgeVariant::Outline
    Muted => @rui.BadgeVariant::Ghost
    Pinned | Success => @rui.BadgeVariant::Secondary
    Running => @rui.BadgeVariant::Default
    Warn => @rui.BadgeVariant::Destructive
  }
}

///|
/// Semantic tones that RUI's six badge variants cannot express borrow the
/// Instrument semantic pairs. Inline styles win over the variant recipe, which
/// is the documented RUI override path.
fn chip_style(tone : ChipTone) -> Array[String] {
  match tone {
    Success => [
      "background: var(--ok-soft)", "color: var(--ok)", "border-color: transparent",
    ]
    Warn => [
      "background: var(--warn-soft)", "color: var(--warn)", "border-color: transparent",
    ]
    Muted => ["opacity: 0.72"]
    _ => []
  }
}

///|
pub fn chip(text : String, tone : ChipTone, title? : String) -> @html.Html {
  @rui.badge(variant=chip_variant(tone), title?, style=chip_style(tone), text)
}
