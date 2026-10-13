///|
/// Test classifier mirroring the production `target_is_writable` wiring:
/// /tmp always writable; other absolute paths not (workspace root here is
/// implicit-relative, so absolutes cannot be proven inside); relative
/// paths are workspace-relative and writable as `.md` only.
fn test_writable(path : String) -> Bool {
  let normalized = @workspace.normalize_lexical(path)
  if normalized == "/tmp" || normalized.has_prefix("/tmp/") {
    return true
  }
  if normalized.has_prefix("/") {
    return false
  }
  normalized.has_suffix(".md")
}

///|
test "investigation commands are allowed through the denylist" {
  let cases = [
    // The reported false-positive chain.
    "git -C external/cetas/extension status --short; git worktree list; git fetch origin; git rev-parse origin/main",
    "ls -la", "cat src/main.rs", "head -20 log.txt", "pwd", "grep -rn 'plan mode' docs",
    "rg --files | wc -l", "find . -name '*.mbt'", "du -sh _build; df -h", "git status",
    "git diff --stat", "git status && git diff --stat", "git log --oneline -10",
    "git show HEAD~2", "git branch", "git tag -l", "git remote -v", "git rev-parse origin/main",
    // `fetch` updates remote-tracking refs, not the worktree.
     "git fetch origin",
    // Global flag before the subcommand.
     "git -C elsewhere status --short", "git worktree list", "git worktree list --porcelain",
    "moon check --output-json", "moon test --output-json", "sed -n 5p log.txt", "curl https://api.example.com",
    // Shims are stripped: the real command is `ls`.
     "sudo ls", "FOO=1 ls", "echo investigating", "printf '%s' hello", "diff a.txt b.txt",
    "jq '.name' package.json", "which moon; whereis moon", "", "   ",
    // fd duplication is a discard, not a write.
     "moon test --output-json 2>&1", "ls 1>&2",
  ]
  for cmd in cases {
    if !shell_command_is_allowed(cmd, writable=test_writable) {
      fail("expected allowed: '\{cmd}'")
    }
  }
}

///|
test "writes are allowed only inside the writable areas" {
  let cases = [
    // Redirects into /tmp, workspace .md, and /dev/null.
    "ls > /tmp/out", "cat a >> /tmp/b", "moon test --output-json > /tmp/test.log",
    "grep x f | tee /tmp/out", "echo investigating > notes.md", "ls 2>/dev/null",
    "ls 2>/dev/null 1>/tmp/o", "ls >/tmp/glued", "ls >>/tmp/glued",
    // File-mutation commands confined to the writable areas.
     "touch /tmp/x", "rm /tmp/x", "rm -rf /tmp/build", "mkdir -p /tmp/a/b", "cp /tmp/a /tmp/b",
    "mv /tmp/a /tmp/b", "tee /tmp/out",
    // Compound: every segment must hold.
     "echo hi > /tmp/out && cat /tmp/out",
  ]
  for cmd in cases {
    assert_true(shell_command_is_allowed(cmd, writable=test_writable))
  }
}

///|
test "known-mutating commands are denied" {
  let cases = [
    "rm -rf build", "mkdir newdir", "touch file", "cp a b", "mv a b", "chmod +x run.sh",
    "tee out.txt", "wget https://example.com/f", "xargs rm", "git push", "git commit -m x",
    "git -C elsewhere push", "git pull", "git rebase main", "git clean -fd", "git reset --hard",
    "git checkout main", "git stash", "git stash list", "git worktree add ../x",
    "git worktree prune", "git clone https://example.com/r.git", "git init", "git config user.name alice",
    "git cherry-pick abc", "git format-patch -1", "moon fmt", "npm install", "pnpm add left-pad",
    "pip install requests", "sed -i s/a/b/ f", "sed --in-place s/a/b/ f", "find . -delete",
    "find . -name x -exec rm", "python3 script.py", "bash -c 'ls'", "sh x.sh", "make all",
    "ls && rm -rf build", "ls; git push", "sudo rm -rf build",
  ]
  for cmd in cases {
    if shell_command_is_allowed(cmd, writable=test_writable) {
      fail("expected denied: '\{cmd}'")
    }
  }
}

///|
test "writes outside the writable areas are denied" {
  let cases = [
    // Redirection targets outside /tmp and non-.md in the workspace.
    "ls > out.txt", "cat a >> b", "ls > /etc/hosts", "echo x > src/main.rs", "ls > /tmp/../etc/passwd",
    "grep x f | tee out.txt",
    // One non-writable path argument keeps the command denied.
     "cp a /tmp/b", "cp /tmp/a b", "mv /tmp/a ../x", "touch /tmp/../escape", "rm /tmp/../etc/passwd",
    // Mode/owner specs are not paths: these stay unconditionally denied.
     "chmod +x /tmp/run.sh", "chown user /tmp/x",
    // /dev/null is a redirect sink only, never a command target.
     "touch /dev/null", "rm /dev/null",
    // Operators with no target and unrecognized `>` shapes.
     "ls >", "ls >&", "ls >& out.txt",
    // Mutating git forms stay denied even against /tmp.
     "git init /tmp/repo", "git -C /tmp/repo init",
    // Interpreters and arbitrary code stay denied regardless of target.
     "python3 x.py > /tmp/o", "bash -c 'ls' > /tmp/o", "dd of=/tmp/x", "mkfs /tmp/disk",
    "wget -O /tmp/f https://example.com",
    // Substitution hides its text from the analysis.
     "echo $(whoami) > /tmp/o", "echo `whoami` > /tmp/o",
  ]
  for cmd in cases {
    if shell_command_is_allowed(cmd, writable=test_writable) {
      fail("expected denied: '\{cmd}'")
    }
  }
}
