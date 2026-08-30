///|
/// Strip a leading `./` (ripgrep spells relative results this way; the
/// walkers do not) so both engines emit identical paths.
pub fn strip_dot_prefix(path : String) -> String {
  if path.has_prefix("./") {
    path[2:].to_owned()
  } else {
    path
  }
}

///|
/// Path of `sub` relative to `base`: drops a `base + "/"` prefix (or `./`
/// when the base is `.`). Returns `sub` unchanged when it does not live
/// under `base` lexically; returns `""` when the two are equal.
pub fn relative_to_base(base : String, sub : String) -> String {
  if sub == base {
    return ""
  }
  let prefix = if base == "/" { "/" } else { "\{base}/" }
  if sub.has_prefix(prefix) {
    sub[prefix.length():].to_owned()
  } else {
    sub
  }
}

///|
/// Truncate `s` to at most `cap` characters, cutting at a char boundary.
/// Empty strings and short strings pass through unchanged.
pub fn truncate_chars(s : String, cap : Int) -> String {
  if s.length() <= cap {
    return s
  }
  let out = StringBuilder()
  let mut count = 0
  for c in s {
    if count == cap {
      break
    }
    out.write_char(c)
    count += 1
  }
  out.to_string()
}
