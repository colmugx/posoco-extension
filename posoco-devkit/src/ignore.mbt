///|
/// Directory and file names the file tools (grep, glob) prune during
/// traversal. Covers VCS internals and the common build/vendor directories;
/// dot-prefixed entries are additionally caught by `has_hidden_segment`.
/// Hosts override per tool via each tool's constructor.
pub fn default_ignore_patterns() -> Array[String] {
  [
    ".git", ".hg", ".svn", "node_modules", "_build", "target", "dist", "__pycache__",
    ".venv",
  ]
}

///|
/// Does `path` match any ignore pattern? Same semantics as
/// `@workspace.matches_ignore` (kept dependency-free here): the path equals
/// the pattern, starts with `pattern + "/"`, or any path segment equals the
/// pattern. Patterns are plain names, no globs.
pub fn matches_ignore(path : String, patterns : Array[String]) -> Bool {
  for pat in patterns {
    if path == pat || path.has_prefix(pat + "/") {
      return true
    }
    for seg in path.split("/") {
      if seg == pat {
        return true
      }
    }
  }
  false
}

///|
/// Does any segment of `path` start with `.`? Mirrors ripgrep's default
/// hidden-entry skipping; callers apply it below the scan base only, so an
/// explicitly requested base like `.config/x` still searches.
pub fn has_hidden_segment(path : String) -> Bool {
  for seg in path.split("/") {
    if seg != "" && seg.has_prefix(".") {
      return true
    }
  }
  false
}

///|
/// Segment glob match: `*` matches any characters within one path segment,
/// `**` matches zero or more whole segments (a trailing `**` matches
/// everything remaining). Used for grep's `glob` file filter and ignore
/// handling; richer syntax (`?`, `{a,b}`, classes) is not supported.
pub fn glob_match(pattern : String, path : String) -> Bool {
  glob_match_segments(
    pattern.split("/").to_array(),
    0,
    path.split("/").to_array(),
    0,
  )
}

///|
fn glob_match_segments(
  pat : Array[StringView],
  pi : Int,
  path : Array[StringView],
  si : Int,
) -> Bool {
  if pi >= pat.length() {
    return si >= path.length()
  }
  if pat[pi] == "**" {
    if pi + 1 == pat.length() {
      return true
    }
    let mut next = si
    while next <= path.length() {
      if glob_match_segments(pat, pi + 1, path, next) {
        return true
      }
      next += 1
    }
    return false
  }
  if si >= path.length() {
    return false
  }
  if glob_seg_match(pat[pi], path[si]) {
    return glob_match_segments(pat, pi + 1, path, si + 1)
  }
  false
}

///|
fn glob_seg_match(pat_seg : StringView, path_seg : StringView) -> Bool {
  if !pat_seg.contains("*") {
    return pat_seg == path_seg
  }
  glob_wildcard_match(pat_seg.iter().collect(), 0, path_seg.iter().collect(), 0)
}

///|
fn glob_wildcard_match(
  pat : Array[Char],
  pi : Int,
  text : Array[Char],
  ti : Int,
) -> Bool {
  if pi >= pat.length() {
    return ti >= text.length()
  }
  if pat[pi] == '*' {
    let mut next = ti
    while next <= text.length() {
      if glob_wildcard_match(pat, pi + 1, text, next) {
        return true
      }
      next += 1
    }
    return false
  }
  if ti >= text.length() {
    return false
  }
  if pat[pi] == text[ti] {
    return glob_wildcard_match(pat, pi + 1, text, ti + 1)
  }
  false
}
