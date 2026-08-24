///|
/// White-box contract tests for WorkspaceFs backends.
///
/// Pure-lexical policy tests run on every target (no IO). The fs round-trip
/// test is `#cfg(target="native")` because `@fs.tmpdir` is native-only;
/// mirroring the glob/write exts' convention. The js backend (`JsWorkspaceFs`)
/// is exercised by the host (cetas-js) integration tests instead.

// ──────────────────────────────────────────────────────────────────────────
// Pure-lexical policy tests — every target, no IO
// ──────────────────────────────────────────────────────────────────────────

///|
test "normalize_lexical_collapses_dotdot_and_slashes" {
  assert_eq(normalize_lexical("/a/b/../c"), "/a/c")
  assert_eq(normalize_lexical("/a//b/./c"), "/a/b/c")
  assert_eq(normalize_lexical("a/b/../../c"), "c")
  assert_eq(normalize_lexical("/"), "/")
  assert_eq(normalize_lexical("."), ".")
}

///|
test "is_lexically_inside_rejects_escape" {
  assert_true(is_lexically_inside("/ws/src/x.mbt", "/ws"))
  assert_true(is_lexically_inside("/ws", "/ws"))
  // `..` escapes root even when the prefix looks right.
  assert_false(is_lexically_inside("/ws/../etc/passwd", "/ws"))
  assert_false(is_lexically_inside("/other/x", "/ws"))
}

///|
test "matches_ignore_directory_prefix_and_segment" {
  let patterns = ["node_modules", ".git"]
  // Exact and directory-prefix match.
  assert_true(matches_ignore("node_modules", patterns))
  assert_true(matches_ignore("node_modules/foo.js", patterns))
  // Nested segment match (gitignore semantics).
  assert_true(matches_ignore("src/node_modules/x", patterns))
  assert_true(matches_ignore(".git/HEAD", patterns))
  // Non-matching.
  assert_false(matches_ignore("src/main.mbt", patterns))
}

///|
test "glob_match_star_and_double_star" {
  // Single `*` within a segment.
  assert_true(glob_match("*.mbt", "foo.mbt"))
  assert_false(glob_match("*.mbt", "foo.txt"))
  // `**` across segments.
  assert_true(glob_match("src/**/*.mbt", "src/a/b/c.mbt"))
  assert_true(glob_match("src/**/*.mbt", "src/x.mbt"))
  assert_false(glob_match("src/**/*.mbt", "test/x.mbt"))
}

///|
test "workspace_policy_new_rejects_cwd_outside_root" {
  let result = WorkspacePolicy::checked(root="/ws", default_cwd="/other")
  match result {
    Err(message) => assert_true(message.contains("not inside root"))
    Ok(_) => fail("expected cwd-outside-root to be rejected")
  }
}

///|
test "workspace_policy_new_defaults_cwd_to_root" {
  let result = WorkspacePolicy::checked(root="/ws")
  match result {
    Ok(policy) => assert_eq(policy.default_cwd, "/ws")
    Err(_) => fail("expected default cwd to fall back to root")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// WorkspaceFs round-trip — native only (needs @fs.tmpdir)
// ──────────────────────────────────────────────────────────────────────────

///|
#cfg(target="native")
async test "native_workspace_fs_roundtrip_mkdir_write_read_readdir_rename_remove" {
  @async.with_task_group() <| group => {
    let base = @fs.tmpdir(prefix="posoco-ws-roundtrip")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(base, recursive=true))
    }
    let fs = NativeWorkspaceFs()
    // mkdir recursive, then a subdir.
    fs.mkdir(base + "/sub/deeper", recursive=true)
    // write + read back.
    fs.write_file(base + "/hello.txt", "world")
    let read_back = fs.read_file(base + "/hello.txt")
    assert_eq(read_back, "world")
    // kind: file vs dir.
    let kind_file = fs.kind(base + "/hello.txt", follow_symlink=true)
    assert_true(kind_file is File)
    let kind_dir = fs.kind(base + "/sub", follow_symlink=true)
    assert_true(kind_dir is Dir)
    // readdir sees the file and subdir.
    let entries = fs.readdir(base, include_hidden=false)
    assert_true(entries.contains("hello.txt"))
    assert_true(entries.contains("sub"))
    // realpath of the base is itself (resolved).
    let resolved = fs.realpath(base)
    assert_true(resolved.contains("posoco-ws-roundtrip"))
    // rename replaces the file.
    fs.rename(base + "/hello.txt", base + "/renamed.txt", replace=true)
    assert_false(fs.exists(base + "/hello.txt"))
    assert_eq(fs.read_file(base + "/renamed.txt"), "world")
    // remove a single file.
    fs.remove(base + "/renamed.txt")
    assert_false(fs.exists(base + "/renamed.txt"))
  }
}

///|
#cfg(target="native")
async test "native_workspace_fs_walk_visits_each_directory" {
  @async.with_task_group() <| group => {
    let base = @fs.tmpdir(prefix="posoco-ws-walk")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(base, recursive=true))
    }
    let fs = NativeWorkspaceFs()
    fs.mkdir(base + "/a/b", recursive=true)
    fs.write_file(base + "/a/one.txt", "1")
    fs.write_file(base + "/a/b/two.txt", "2")
    let visited : Array[String] = []
    fs.walk(base, fn(_dir, _entries) { visited.push(_dir) })
    // root, a, a/b all visited (order: depth-first root-first).
    assert_true(visited.length() >= 3)
    assert_true(visited.contains(base))
  }
}

///|
#cfg(target="native")
async test "read_file_result_missing_content_failed" {
  @async.with_task_group() <| group => {
    let base = @fs.tmpdir(prefix="posoco-ws-readresult")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(base, recursive=true))
    }
    let fs = NativeWorkspaceFs()
    // Missing: absent optional source.
    assert_true(read_file_result(fs, base + "/nope.txt") is Missing)
    // Content: present file round-trips.
    fs.write_file(base + "/present.txt", "hello")
    match read_file_result(fs, base + "/present.txt") {
      Content(value) => assert_eq(value, "hello")
      _ => fail("expected Content")
    }
    // Failed: path exists but is a directory, not a readable file.
    fs.mkdir(base + "/dir", recursive=true)
    match read_file_result(fs, base + "/dir") {
      Failed(_) => ()
      other => {
        debug_inspect(other)
        fail("expected Failed")
      }
    }
  }
}

///|
#cfg(target="native")
async test "native_write_file_atomic_replaces_destination" {
  @async.with_task_group() <| group => {
    let base = @fs.tmpdir(prefix="posoco-ws-atomic")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(base, recursive=true))
    }
    let fs = NativeWorkspaceFs()
    fs.write_file_atomic(base + "/cred.json", "v1")
    assert_eq(fs.read_file(base + "/cred.json"), "v1")
    // Atomic replace over an existing destination.
    fs.write_file_atomic(base + "/cred.json", "v2")
    assert_eq(fs.read_file(base + "/cred.json"), "v2")
    // No temp file survives a successful replace.
    let entries = fs.readdir(base, include_hidden=false)
    assert_eq(entries, ["cred.json"])
  }
}
