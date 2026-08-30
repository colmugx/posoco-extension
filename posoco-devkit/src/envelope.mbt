///|
/// XML-escape text content so interpolated values cannot break out of the
/// envelope or inject attributes. Single pass; only the five significant
/// characters are rewritten.
fn escape_xml(s : String) -> String {
  let sb = StringBuilder()
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
/// `<{ns}-context type="{kind}" trust="{trust}"[ source="{source}"][ {name}="{value}"…]…</{ns}-context>`.
/// `ns` is the composing host's bare namespace (e.g. cetas hosts pass
/// `"cetas"` and get `<cetas-context>`); it, `kind`, and custom attribute
/// names are trusted host configuration and are not escaped. `source`
/// (rendered only when passed), custom attribute values, and `content`
/// are escaped because they may carry external or dynamic text. Custom
/// attributes render after the standard ones, in the given order.
#alias(render_context_envelope, deprecated="renamed to context_envelope")
pub fn context_envelope(
  ns~ : String,
  kind~ : String,
  trust~ : Bool,
  source? : String,
  attrs? : Array[(String, String)] = [],
  content~ : String,
) -> String {
  let trust_str = if trust { "true" } else { "false" }
  let sb : StringBuilder = StringBuilder()
  sb <+ "<\{ns}-context type=\"\{kind}\" trust=\"\{trust_str}\""
  if source is Some(s) {
    sb <+ " source=\"\{escape_xml(s)}\""
  }
  for pair in attrs {
    let (name, value) = pair
    sb <+ " \{name}=\"\{escape_xml(value)}\""
  }
  sb <+ ">\n\{escape_xml(content)}\n</\{ns}-context>"
  sb.to_string()
}
