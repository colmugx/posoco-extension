///|
/// Whether `ch` carries no printable content of its own: controls, format
/// characters, lone surrogates, and the line/paragraph separators. The
/// classification comes from the Unicode Character Database instead of a
/// hand-maintained range list, so new assignments such as the tag characters
/// are covered without editing this file.
///
/// Deliberately not `is_default_ignorable_code_point`: that property also
/// covers the variation selectors (`U+FE00..U+FE0F`) and `U+3164`, which are
/// visible presentation state, not hidden text.
pub fn is_control(ch : Char) -> Bool {
  match @ucd.general_category(ch) {
    Cc | Cf | Cs | Zl | Zp => true
    _ => false
  }
}

///|
/// Display counterpart of `is_control`: a rendered block keeps the two
/// whitespace controls that carry line structure, plus the joiners that hold
/// ZWJ emoji and Persian/Arabic clusters together.
fn is_display_unsafe(ch : Char) -> Bool {
  is_control(ch) &&
  ch != '\t' &&
  ch != '\n' &&
  ch != '\u{200C}' &&
  ch != '\u{200D}'
}

///|
/// Delete the scalars a multi-line rendered block cannot show, so untrusted
/// text cannot reorder, hide, or forge what surrounds it.
///
/// Tab, newline, ZWJ and ZWNJ survive; the variation selectors are `Mn`, not
/// format characters, so emoji presentation is unaffected. Tag characters
/// (`U+E0020..U+E007F`) are format characters and are removed, which flattens
/// subdivision-flag emoji to their base glyph — the invisible channel they
/// provide is not worth keeping.
pub fn display_strip(text : String) -> String {
  guard text.find_by(ch => is_display_unsafe(ch)) is Some(_) else {
    return text
  }
  let builder = StringBuilder(size_hint=text.length())
  for ch in text {
    if !is_display_unsafe(ch) {
      builder.write_char(ch)
    }
  }
  builder.to_string()
}

///|
/// Single-line counterpart of `display_strip`: on a label every control scalar
/// — including tab, newline and the joiners — would break the row, so each one
/// becomes `replacement`.
///
/// This bounds payload, not columns: terminal width is the renderer's decision
/// (`pi-tui` on JS, `go-runewidth` on native), and those clippers measure the
/// same string again.
pub fn display_label(text : String, replacement~ : Char = ' ') -> String {
  guard text.find_by(ch => is_control(ch)) is Some(_) else { return text }
  let builder = StringBuilder(size_hint=text.length())
  for ch in text {
    builder.write_char(if is_control(ch) { replacement } else { ch })
  }
  builder.to_string()
}

///|
/// Keep user-controlled paths bounded and single-line in diagnostics.
/// Truncates at `limit` chars (default 160), appending `...` when truncated.
/// Every control character (newlines, tabs, escape sequences, DEL, …) is
/// replaced with a space so the result cannot forge terminal output.
///
/// `limit` counts scalars, not terminal columns: a CJK path occupies more
/// columns than its length, and clamping to a column budget belongs to the
/// renderer that owns the width.
pub fn sanitize_path(path : String, limit~ : Int32 = 160) -> String {
  let builder = StringBuilder()
  let mut count = 0
  for ch in path {
    if count >= limit {
      builder.write_string("...")
      break
    }
    builder.write_char(if is_control(ch) { ' ' } else { ch })
    count += 1
  }
  builder.to_string()
}

///|
/// Same as `sanitize_path` with a shorter default limit (120) suitable for
/// diagnostic labels such as tool/server names in MCP.
pub fn sanitize_label(label : String, limit~ : Int32 = 120) -> String {
  sanitize_path(label, limit~)
}
