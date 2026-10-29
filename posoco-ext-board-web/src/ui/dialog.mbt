// Native-dialog shell for the Board.
//
// RUI's `dialog` is a styled native `<dialog>` opened with a browser `showModal`
// and closed by a `<form method="dialog">` submit — the same contract as the
// shell's own `ui_show`/`ui_close` helpers, so the app keeps owning visibility
// and focus return while RUI owns the panel recipe and the close affordance.
//
// `padding:0` is deliberate: each dialog keeps its own `.dialog-shell` layout,
// and the caller passes whatever width that content needs.

///|
pub fn dialog(
  id : String,
  label : String,
  on_close : @rabbita.Emit[String],
  style : Array[String],
  children : Array[@html.Html],
) -> @html.Html {
  @rui.dialog(
    id~,
    closedby="any",
    on_close~,
    attrs=@html.Attrs::build().aria_label(label),
    style=["padding:0", ..style],
    children,
  )
}

///|
/// A right-edge drawer built on the same native `<dialog>`: flush to the
/// viewport edge, full height, one hairline on its left edge. RUI's default
/// panel recipe is a floating centred card, which reads as a modal rather than
/// a drawer, so the sheet variant restates the geometry.
pub fn sheet_dialog(
  id : String,
  label : String,
  on_close : @rabbita.Emit[String],
  width : String,
  children : Array[@html.Html],
) -> @html.Html {
  @rui.dialog(
    id~,
    // Marker class: the drawer motion lives in `public/board.css`, because it
    // has to override RUI's fade-and-scale dialog transition.
    class="sheet-dialog",
    closedby="any",
    on_close~,
    attrs=@html.Attrs::build().aria_label(label),
    style=[
      "padding:0",
      "border-radius:0",
      "box-shadow:-1px 0 0 var(--line)",
      // `min(..., 100vw)`: a fixed drawer width must never exceed a narrow
      // viewport, otherwise the panel hangs off the left edge.
      "width:min(\{width}, 100vw)",
      "max-width:none",
      "height:100dvh",
      "max-height:none",
      "inset-block:0",
      "margin:0 0 0 auto",
    ],
    children,
  )
}
