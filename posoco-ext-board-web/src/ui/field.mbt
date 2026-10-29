// Form field primitives.

///|
/// One labelled control. The label is associated by `for_`, and the caller owns
/// the control, so this never guesses at another component's ids.
pub fn labeled_field(
  id : String,
  label_text : String,
  control : @html.Html,
) -> @html.Html {
  @html.div(class="field", [@html.label(for_=id, label_text), control])
}
