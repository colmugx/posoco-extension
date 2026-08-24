///|
/// Tests for the shared read-only shell classifier.

///|
test "read-only commands classify as read-only" {
  let cases = [
    "ls -la", "ls", "cat src/main.rs", "head -20 log.txt", "tail -n 5 log.txt", "pwd",
    "find . -name '*.mbt' | head -20", "grep -rn 'plan mode' docs", "rg --files | wc -l",
    "git status", "git diff --stat", "git status && git diff --stat", "git log --oneline -10",
    "git show HEAD~2", "git branch", "stat package.json; file package.json", "which moon; whereis moon",
    "du -sh _build", "df -h", "echo investigating", "printf '%s' hello", "diff a.txt b.txt",
    "jq '.name' package.json", "basename src/main.rs",
  ]
  for cmd in cases {
    assert_true(shell_command_is_read_only(cmd))
  }
}

///|
test "mutating or opaque commands classify as not read-only" {
  let cases = [
    "", "   ", "rm -rf build", "mkdir newdir", "touch file", "cp a b", "mv a b",
    "npm install", "python3 script.py", "git push", "git commit -m x", "git stash",
    "git config user.name colmugx", "git worktree add ../x", "ls > out.txt", "cat a >> b",
    "echo $(whoami)", "echo `whoami`", "ls && rm -rf build", "ls; rm x", "ls | xargs rm",
    "grep x f | tee out.txt", "sudo ls", "bash -c 'ls'", "FOO=1 ls", "sed -i s/a/b/ f",
    "curl http://example.com",
  ]
  for cmd in cases {
    assert_false(shell_command_is_read_only(cmd))
  }
}
