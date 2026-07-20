///|
/// Keep user-controlled paths bounded and single-line in diagnostics.
/// Truncates at `limit` chars (default 160), replacing control chars with spaces.
pub fn sanitize_path(path : String, limit? : Int = 160) -> String {
  let builder = StringBuilder::new()
  let mut count = 0
  for ch in path {
    if count >= limit {
      builder.write_string("...")
      break
    }
    match ch {
      '\n' | '\r' | '\t' => builder.write_char(' ')
      _ => builder.write_char(ch)
    }
    count += 1
  }
  builder.to_string()
}

///|
/// Same as `sanitize_path` with a shorter default limit (120) suitable for
/// diagnostic labels such as tool/server names in MCP.
pub fn sanitize_label(label : String, limit? : Int = 120) -> String {
  sanitize_path(label, limit~)
}
