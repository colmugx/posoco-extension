// Form controls.
//
// RUI's controls carry an inline font recipe that asks for Inter. The Board is
// read mostly as CJK titles, so every control here appends the Instrument font
// stack last, which is the one thing a caller style may win against.

///|
let control_style : Array[String] = ["font-family: var(--font-sans)"]

///|
pub fn text_input(
  id~ : String,
  name~ : String,
  label? : String,
  value~ : String,
  placeholder~ : String,
  disabled~ : Bool,
  autofocus~ : Bool,
  aria_label~ : String,
  on_input~ : @rabbita.Emit[String],
) -> @html.Html {
  let attrs = @html.Attrs::build().aria_label(aria_label)
  let attrs = if autofocus {
    attrs.data_set("autofocus", "true")
  } else {
    attrs
  }
  let control = @rui.input(
    id~,
    name~,
    value~,
    placeholder~,
    disabled~,
    on_input~,
    attrs~,
    style=control_style,
  )
  match label {
    Some(text) => labeled_field(id, text, control)
    None => control
  }
}

///|
pub fn text_area(
  id~ : String,
  name~ : String,
  label? : String,
  value~ : String,
  rows~ : Int32,
  placeholder~ : String,
  disabled~ : Bool,
  class? : String,
  aria_label? : String,
  on_input~ : @rabbita.Emit[String],
) -> @html.Html {
  let attrs = @html.Attrs::build()
  let attrs = match aria_label {
    Some(text) => attrs.aria_label(text)
    None => attrs
  }
  let control = @rui.textarea(
    id~,
    name~,
    value~,
    rows~,
    placeholder~,
    disabled~,
    class?,
    attrs~,
    on_input~,
    style=control_style,
  )
  match label {
    Some(text) => labeled_field(id, text, control)
    None => control
  }
}

///|
pub fn select_field(
  id~ : String,
  name~ : String,
  label? : String,
  value? : String,
  disabled~ : Bool,
  aria_label? : String,
  on_change~ : @rabbita.Emit[String],
  options : Array[@html.Html],
) -> @html.Html {
  // RUI wraps the select in a `width:fit-content` shell. Inside a labelled
  // field the control must fill the column; in a toolbar row it must stay
  // intrinsic, so the wrapper is the caller-visible sizing knob.
  let wrapper_style = match label {
    Some(_) => ["width:100%", "max-width:100%"]
    None => ["width:auto"]
  }
  let control = @rui.native_select(
    id~,
    name~,
    value?,
    disabled~,
    aria_label?,
    on_change~,
    style=control_style,
    wrapper_style~,
    options,
  )
  match label {
    Some(text) => labeled_field(id, text, control)
    None => control
  }
}

///|
/// Loading placeholder line. RUI supplies the pulse and the radius; the caller
/// supplies only the width class that the board layout needs.
pub fn skeleton_line(class : String) -> @html.Html {
  @rui.skeleton(class~)
}

///|
/// A search box for a toolbar: no label, an explicit aria label.
pub fn search_input(
  id~ : String,
  placeholder~ : String,
  value~ : String,
  aria_label~ : String,
  on_input~ : @rabbita.Emit[String],
  style~ : Array[String] = [],
) -> @html.Html {
  @rui.input(
    input_type=@html.InputType::Search,
    id~,
    placeholder~,
    value~,
    on_input~,
    attrs=@html.Attrs::build().aria_label(aria_label),
    // RUI's input is `width:100%`; inside a flex toolbar the caller decides.
    style=["font-family: var(--font-sans)", ..style],
  )
}
