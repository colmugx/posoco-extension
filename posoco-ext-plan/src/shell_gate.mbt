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
/// Allowed iff no segment (split on `&&`/`||`/`;`/`|`/`&`/newlines)
/// resolves to a denylisted mutation: leading shims are stripped, `git`
/// segments are scanned for mutating subcommands, and the paired tables
/// catch mutating subcommands/flags of otherwise read-only commands. Raw
/// `>` redirection and `$(…)`/backtick substitution always deny — the
/// first writes, the second hides text from this analysis.
///
/// NOT a security boundary: quotes are not parsed, flag values are not
/// analyzed, unknown commands are allowed. Plan mode is steering; enforce
/// with a permission layer.
fn shell_command_is_allowed(cmd : String) -> Bool {
  if cmd.trim().length() == 0 {
    return true
  }
  // Raw disqualifiers the segment scan cannot see.
  if cmd.contains(">") {
    return false
  }
  if cmd.contains("$(") || cmd.contains("`") {
    return false
  }
  for segment in split_shell_segments(cmd) {
    let words = segment_words(segment)
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
