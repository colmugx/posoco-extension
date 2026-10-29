// Connection-level notices.
//
// One card for both surfaces — the inline banner inside a dialog and the toast
// at the bottom of the board. RUI owns the surface, the shell owns the copy.

///|
/// What the notice is telling the operator.
pub(all) enum NoticeTone {
  Success
  Warning
  Error
}

///|
fn notice_variant(tone : NoticeTone) -> @rui.ToastVariant {
  match tone {
    Success => @rui.ToastVariant::ToastSuccess
    Warning => @rui.ToastVariant::ToastDefault
    Error => @rui.ToastVariant::ToastDestructive
  }
}

///|
fn notice_card(
  tone : NoticeTone,
  text : String,
  action : @html.Html,
  on_dismiss : @rabbita.Cmd,
  class? : String,
) -> @html.Html {
  @rui.toast(variant=notice_variant(tone), class?, [
    @html.span(text),
    action,
    @html.button(
      type_="button",
      class="btn btn-sm btn-ghost",
      title="Dismiss notification",
      attrs=@html.Attrs::build().aria_label("Dismiss notification"),
      on_click=on_dismiss,
      "✕",
    ),
  ])
}

///|
pub fn notice(
  tone : NoticeTone,
  text : String,
  on_dismiss~ : @rabbita.Cmd,
  class? : String,
) -> @html.Html {
  notice_card(tone, text, @html.nothing, on_dismiss, class?)
}

///|
/// A notice that offers one recovery command, for example undoing a move.
pub fn notice_with_action(
  tone : NoticeTone,
  text : String,
  action_label~ : String,
  action_aria~ : String,
  action_cmd~ : @rabbita.Cmd,
  on_dismiss~ : @rabbita.Cmd,
  class? : String,
) -> @html.Html {
  notice_card(
    tone,
    text,
    @html.button(
      type_="button",
      class="btn btn-sm",
      attrs=@html.Attrs::build().aria_label(action_aria),
      on_click=action_cmd,
      action_label,
    ),
    on_dismiss,
    class?,
  )
}
