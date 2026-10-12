///|
/// Plan mode's own shell command gate: a denylist. This table is plan-mode
/// steering and deliberately diverges from the permission gate's copy, which
/// keeps a read-only allowlist for inspection auto-approval: there an
/// unknown command must ask, here an unknown command may run — plan mode
/// only steers the model away from mutations; enforcement stays with the
/// permission layer.

///|
/// Commands whose every invocation mutates something (files, permissions,
/// processes) or executes arbitrary code this analysis cannot see into.
/// Entries also in `shell_confined_ok_commands` get a writable-area
/// carve-out; the rest are denied unconditionally.
let shell_deny_commands : Array[String] = [
  // File mutation.
  "rm", "rmdir", "mv", "cp", "mkdir", "touch", "ln", "dd", "shred", "truncate", "chmod",
  "chown", "chgrp", "mkfs", "tee", "wget",
  // Interpreters and shells: their argument IS arbitrary code.
   "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "node", "perl",
  "ruby", "php", "java", "make", "eval", "exec", "source",
  // Runs its arguments/stdin as commands.
   "xargs",
  // Privilege escalation and process kill.
   "sudo", "doas", "kill", "pkill", "killall",
]

///|
/// File-mutation commands that may run while planning when EVERY path
/// argument is writable (/tmp-style roots, workspace `.md`): `touch /tmp/x`,
/// `rm -rf /tmp/build`, `cp /tmp/a /tmp/b`, `grep x f | tee /tmp/out`. A
/// single non-writable path argument (`cp a /tmp/b`) keeps the command
/// denied. `chmod`/`chown`/`chgrp` stay outside — their first argument is
/// a mode or owner spec, not a path. Interpreters, `dd` (`of=` targets),
/// `mkfs`, `wget`, and the process/privilege commands stay outside too.
let shell_confined_ok_commands : Array[String] = [
  "rm", "rmdir", "mv", "cp", "mkdir", "touch", "ln", "shred", "truncate", "tee",
]

///|
/// Leading shims that do not mutate by themselves; stripped so the real
/// command behind `sudo rm` / `env python3 …` is still classified.
let shell_shims : Array[String] = [
  "sudo", "doas", "env", "nohup", "nice", "time",
]

///|
/// (command, mutating subcommands): the command itself is often read-only,
/// only these forms mutate.
let shell_deny_subcommands : Array[(String, Array[String])] = [
  ("moon", ["fmt"]),
  ("npm", ["install", "ci", "publish", "uninstall", "link"]),
  ("pnpm", ["install", "add", "remove", "publish", "link"]),
  ("yarn", ["add", "remove", "publish", "link"]),
  ("pip", ["install", "uninstall"]),
  ("pip3", ["install", "uninstall"]),
]

///|
/// (command, flag prefixes) where a flag flips the command into in-place
/// mutation (`sed -i`, `find -delete` / `-exec`). Prefix match, so glued
/// short flags like `-in` are caught too.
let shell_deny_flags : Array[(String, Array[String])] = [
  ("sed", ["-i", "--in-place"]),
  ("find", ["-delete", "-exec", "-execdir", "-ok", "-okdir"]),
]

///|
/// Git subcommands that always mutate something — refs, worktree, config,
/// or repo state. The ambiguous ones (`branch`, `tag`, `remote`) stay
/// allowed because their listing forms dominate planning; two-word flag
/// analysis is out of scope, so read forms of the entries above (`git
/// config user.name`, `git stash list`) are denied along with their
/// mutating siblings.
let git_deny_subcommands : Array[String] = [
  "init", "clone", "commit", "push", "pull", "merge", "rebase", "reset", "revert",
  "clean", "checkout", "switch", "restore", "stash", "apply", "am", "cherry-pick",
  "rm", "mv", "gc", "prune", "repack", "filter-branch", "bisect", "config", "format-patch",
  "submodule",
]

///|
fn is_shell_separator(c : Char) -> Bool {
  c == ';' || c == '|' || c == '&' || c == '\n'
}

///|
fn split_shell_segments(cmd : String) -> Array[String] {
  let segments : Array[String] = []
  let mut sb = StringBuilder()
  let mut prev = ' '
  for c in cmd {
    if is_shell_separator(c) {
      // An `&` right after `>` is an fd duplication (`2>&1`), not a
      // separator — keep it in the segment so the word analysis sees the
      // whole token.
      if c == '&' && prev == '>' {
        sb.write_char(c)
        prev = c
        continue
      }
      let text = sb.to_string()
      if text.trim().length() > 0 {
        segments.push(text)
      }
      sb = StringBuilder()
      prev = c
      continue
    }
    sb.write_char(c)
    prev = c
  }
  let tail = sb.to_string()
  if tail.trim().length() > 0 {
    segments.push(tail)
  }
  segments
}

///|
fn segment_words(segment : String) -> Array[String] {
  let words : Array[String] = []
  let current = StringBuilder()
  for c in segment {
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      if current.to_string().length() > 0 {
        words.push(current.to_string())
        current.reset()
      }
    } else {
      current.write_char(c)
    }
  }
  if current.to_string().length() > 0 {
    words.push(current.to_string())
  }
  words
}

///|
fn subcommand_denied(cmd : String, words : Array[String]) -> Bool {
  for entry in shell_deny_subcommands {
    let (name, subs) = entry
    if name == cmd {
      return words.length() > 1 && subs.contains(words[1])
    }
  }
  false
}

///|
fn flag_denied(cmd : String, words : Array[String]) -> Bool {
  for entry in shell_deny_flags {
    let (name, prefixes) = entry
    if name == cmd {
      for i in 1..<words.length() {
        for prefix in prefixes {
          if words[i].has_prefix(prefix) {
            return true
          }
        }
      }
    }
  }
  false
}

///|
/// Scans every word, so global flags before the subcommand
/// (`git -C elsewhere push`) cannot smuggle a mutation past.
/// `git worktree` is denied except `git worktree list`.
fn git_words_denied(words : Array[String], start~ : Int) -> Bool {
  let mut i = start
  while i < words.length() {
    let word = words[i]
    if word == "worktree" {
      if i + 1 < words.length() && words[i + 1] == "list" {
        i = i + 2
      } else {
        return true
      }
    } else if git_deny_subcommands.contains(word) {
      return true
    } else {
      i = i + 1
    }
  }
  false
}

///|
/// One word containing `>`: an fd duplication to skip (`2>&1`), a bare
/// operator whose target is the next word (`> /tmp/out`), a glued
/// operator+target (`>/tmp/out`), or an unrecognized shape that denies.
priv enum RedirectWord {
  Dup
  Bare
  Glued(String)
  Unknown
}

///|
/// Output operators, longest first so `>>`/`2>>`/`&>>`/`1>>` win their
/// match.
let redirect_ops : Array[String] = [
  ">>", "2>>", "&>>", "1>>", ">", "2>", "1>", "&>",
]

///|
fn all_digits(s : String) -> Bool {
  for ch in s {
    if !(ch >= '0' && ch <= '9') {
      return false
    }
  }
  true
}

///|
/// fd duplication shapes `[0-9]*>&[0-9]*`: `2>&1`, `>&2`, `1>&2`. The bare
/// `>&` (both sides empty) is excluded — bash reads `>& file` as a dup
/// INTO a file, so it is a write, not a discard.
fn redirect_dup_ok(word : String) -> Bool {
  match word.find(">&") {
    Some(pos) => {
      let lhs = word[:pos].to_owned()
      let rhs = word[pos + 2:word.length()].to_owned()
      (lhs.length() > 0 || rhs.length() > 0) &&
      all_digits(lhs) &&
      all_digits(rhs)
    }
    None => false
  }
}

///|
fn classify_redirect(word : String) -> RedirectWord {
  if redirect_dup_ok(word) {
    return Dup
  }
  for op in redirect_ops {
    if word == op {
      return Bare
    }
    if word.has_prefix(op) && word.length() > op.length() {
      return Glued(word[op.length():word.length()].to_owned())
    }
  }
  Unknown
}

///|
fn redirect_target_ok(target : String, writable~ : (String) -> Bool) -> Bool {
  // Discard, not persistence: stderr suppression is investigation bread
  // and butter. The one target exempt from the writable check.
  target == "/dev/null" || writable(target)
}

///|
/// Every output redirection in the segment must target a writable path
/// (or /dev/null); an operator with no target word and any unrecognized
/// `>` shape deny.
fn redirects_denied(
  words : Array[String],
  writable~ : (String) -> Bool,
) -> Bool {
  let mut i = 0
  while i < words.length() {
    let word = words[i]
    if word.contains(">") {
      match classify_redirect(word) {
        Dup => ()
        Bare => {
          if i + 1 >= words.length() ||
            !redirect_target_ok(words[i + 1], writable~) {
            return true
          }
          i = i + 2
          continue
        }
        Glued(target) =>
          if !redirect_target_ok(target, writable~) {
            return true
          }
        Unknown => return true
      }
    }
    i = i + 1
  }
  false
}

///|
/// All non-flag arguments resolve to writable paths? Flags (incl. glued
/// short forms like `-rf`) carry no path.
fn args_confined(
  words : Array[String],
  start~ : Int,
  writable~ : (String) -> Bool,
) -> Bool {
  for i in start..<words.length() {
    let word = words[i]
    if !word.has_prefix("-") && !writable(word) {
      return false
    }
  }
  true
}

///|
/// Allowed iff no segment (split on `&&`/`||`/`;`/`|`/`&`/newlines)
/// can write outside the writable areas: every output redirection must
/// target a `writable` path or /dev/null, leading shims are stripped,
/// `git` segments are scanned for mutating subcommands, denylisted
/// file-mutation commands pass only when all their path arguments are
/// `writable`, and the paired tables catch mutating subcommands/flags of
/// otherwise read-only commands. Raw `$(…)`/backtick substitution always
/// denies — it hides text from this analysis.
///
/// NOT a security boundary: quotes are not parsed, flag values are not
/// analyzed, unknown commands are allowed. Plan mode is steering; enforce
/// with a permission layer.
fn shell_command_is_allowed(cmd : String, writable~ : (String) -> Bool) -> Bool {
  if cmd.trim().length() == 0 {
    return true
  }
  // Arbitrary code this analysis cannot see into.
  if cmd.contains("$(") || cmd.contains("`") {
    return false
  }
  for segment in split_shell_segments(cmd) {
    let words = segment_words(segment)
    if redirects_denied(words, writable~) {
      return false
    }
    let mut start = 0
    while start < words.length() && shell_shims.contains(words[start]) {
      start = start + 1
    }
    if start == words.length() {
      // `sudo`, `env FOO=1 …` with no command: nothing executes.
      continue
    }
    let first = words[start]
    let denied = if first == "git" {
      git_words_denied(words, start=start + 1)
    } else if shell_confined_ok_commands.contains(first) {
      !args_confined(words, start=start + 1, writable~)
    } else {
      shell_deny_commands.contains(first) ||
      subcommand_denied(first, words) ||
      flag_denied(first, words)
    }
    if denied {
      return false
    }
  }
  true
}
