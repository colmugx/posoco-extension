///|
/// XML-escape text content so interpolated values cannot break out of the
/// envelope or inject attributes. Single pass; only the five significant
/// characters are rewritten.
fn escape_xml(s : String) -> String {
  let sb = StringBuilder::new()
  for ch in s {
    match ch {
      '&' => sb.write_string("&amp;")
      '<' => sb.write_string("&lt;")
      '>' => sb.write_string("&gt;")
      '"' => sb.write_string("&quot;")
      '\'' => sb.write_string("&apos;")
      _ => sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
/// Render one context envelope element:
/// `<{envelope} type="{kind}" trust="{trust}" source="{source}">…</{envelope}>`.
/// The `envelope` element name belongs to the composing host (e.g. cetas hosts
/// use `cetas-context`); it and `kind` are trusted host configuration and are
/// not escaped. `source` (rendered only when passed) and `content` are escaped
/// because they carry filesystem-derived text.
pub fn render_context_envelope(
  envelope~ : String,
  kind~ : String,
  trust~ : Bool,
  source? : String,
  content~ : String,
) -> String {
  let trust_str = if trust { "true" } else { "false" }
  let sb : StringBuilder = StringBuilder::new()
  sb <+ "<\{envelope} type=\"\{kind}\" trust=\"\{trust_str}\""
  if source is Some(s) {
    sb <+ " source=\"\{escape_xml(s)}\""
  }
  sb <+ ">\n\{escape_xml(content)}\n</\{envelope}>"
  sb.to_string()
}
