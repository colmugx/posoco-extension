// Connection banners and inline notices.
//
// These render from strings plus a ready-made command: no `Model`, no `Msg`.

///|
/// A passive status banner with the Instrument dot.
pub fn banner(text : String) -> @html.Html {
  @html.div(
    class="banner",
    attrs=@html.Attrs::build().role("status").aria_live("polite"),
    [@html.span(class="banner-dot", ""), @html.span(text)],
  )
}

///|
/// A status banner with one recovery action. The caller supplies the command,
/// so this stays independent of the shell's message type.
pub fn banner_retry(text : String, retry : @rabbita.Cmd) -> @html.Html {
  @html.div(
    class="banner",
    attrs=@html.Attrs::build().role("status").aria_live("polite"),
    [
      @html.span(class="banner-dot", ""),
      @html.span(text),
      @html.button(
        type_="button",
        class="btn btn-sm banner-action",
        on_click=retry,
        "Retry",
      ),
    ],
  )
}
