///|
/// Shared read-only shell command classification for gate-style extensions
/// (plan mode, permission). Contract on `shell_command_is_read_only`.

///|
let read_only_commands : Array[String] = [
  "ls", "cat", "head", "tail", "pwd", "cd", "echo", "printf", "wc", "file", "stat",
  "du", "df", "tree", "find", "fd", "grep", "rg", "ag", "which", "where", "whereis",
  "type", "whoami", "id", "groups", "uname", "arch", "hostname", "date", "uptime",
  "env", "printenv", "ps", "w", "who", "seq", "basename", "dirname", "realpath",
  "readlink", "md5", "md5sum", "shasum", "sha256sum", "cksum", "diff", "cmp", "jq",
]

///|
/// No `config`/`stash`/`worktree`: their write forms are indistinguishable
/// without flag analysis.
let git_read_only_subcommands : Array[String] = [
  "status", "diff", "log", "show", "blame", "branch", "tag", "remote", "describe",
  "shortlog", "grep", "ls-files", "rev-parse", "cat-file", "reflog", "annotate",
]

///|
fn is_shell_separator(c : Char) -> Bool {
  c == ';' || c == '|' || c == '&' || c == '\n'
}

///|
fn split_shell_segments(cmd : String) -> Array[String] {
  let segments : Array[String] = []
  let mut sb = StringBuilder()
  for c in cmd {
    if is_shell_separator(c) {
      let text = sb.to_string()
      if text.trim().length() > 0 {
        segments.push(text)
      }
      sb = StringBuilder()
      continue
    }
    sb.write_char(c)
  }
  let tail = sb.to_string()
  if tail.trim().length() > 0 {
    segments.push(tail)
  }
  segments
}

///|
/// Blank input yields `("", None)`.
fn first_two_words(text : String) -> (String, String?) {
  let words : Array[String] = []
  let mut sb = StringBuilder::new()
  let mut word_len = 0
  for c in text {
    if c == ' ' || c == '\t' || c == '\r' {
      if word_len > 0 {
        words.push(sb.to_string())
        sb = StringBuilder::new()
        word_len = 0
        if words.length() == 2 {
          break
        }
      }
      continue
    }
    sb.write_char(c)
    word_len += 1
  }
  if word_len > 0 && words.length() < 2 {
    words.push(sb.to_string())
  }
  match words.length() {
    0 => ("", None)
    1 => (words[0], None)
    _ => (words[0], Some(words[1]))
  }
}

///|
/// Read-only iff every segment (split on `&&`/`||`/`;`/`|`/`&`/newlines)
/// starts with an allowlisted command — `git` additionally requires a
/// read-only subcommand — and the raw text contains no `>` redirection or
/// `$(…)`/backtick substitution. Empty or unparseable input classifies as
/// mutating.
///
/// NOT a security boundary: flags and quotes are not analyzed, unknown
/// commands classify as mutating. Enforce with a permission layer.
pub fn shell_command_is_read_only(cmd : String) -> Bool {
  if cmd.trim().length() == 0 {
    return false
  }
  // Raw disqualifiers the segment scan cannot see.
  if cmd.contains(">") {
    return false
  }
  if cmd.contains("$(") || cmd.contains("`") {
    return false
  }
  for segment in split_shell_segments(cmd) {
    let (first, second) = first_two_words(segment)
    if first.length() == 0 {
      return false
    }
    if first == "git" {
      match second {
        Some(sub) =>
          if !git_read_only_subcommands.contains(sub) {
            return false
          }
        // Bare `git` prints usage; harmless.
        None => ()
      }
      continue
    }
    if !read_only_commands.contains(first) {
      return false
    }
  }
  true
}
