///|
/// Whether every scalar in `text` is ASCII. ASCII-only text can be matched
/// case-insensitively without a Unicode fold, so callers keep the cheap path.
pub fn is_ascii(text : StringView) -> Bool {
  text.find_by(ch => !ch.is_ascii()) is None
}

///|
/// Simple per-scalar case folding from the Unicode Character Database, i.e. the
/// length-preserving mapping (one scalar in, one scalar out).
///
/// This is the folding `@regexp`'s `i` flag and ripgrep apply, so a literal
/// `-i` search and a regex `-i` search give the same answer. It is deliberately
/// not `@casefold.case_fold`, the full mapping that expands (`ß` -> `ss`): a
/// line-oriented matcher compares folded offsets against the original line, and
/// expanding folds would shift them.
pub fn fold_case(text : StringView) -> String {
  guard text.find_by(ch => @ucd.to_simple_lowercase(ch) != ch) is Some(_) else {
    return text.to_owned()
  }
  let builder = StringBuilder(size_hint=text.length())
  for ch in text {
    builder.write_char(@ucd.to_simple_lowercase(ch))
  }
  builder.to_string()
}
