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
  ]
  for cmd in cases {
    assert_true(shell_command_is_allowed(cmd))
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
    "ls > out.txt", "cat a >> b", "echo $(whoami)", "echo `whoami`", "ls && rm -rf build",
    "ls; git push", "grep x f | tee out.txt", "sudo rm -rf build",
  ]
  for cmd in cases {
    assert_false(shell_command_is_allowed(cmd))
  }
}
