///|
extern "C" fn workspace_test_file_mode(fd : @types.Fd) -> Int = "cetas_workspace_test_file_mode"

///|
async fn with_atomic_test_dir(body : async (String) -> Unit) -> Unit {
  @async.with_task_group() <| group => {
    let base = @fs.tmpdir(prefix="workspace-atomic-test-")
    group.add_defer(() => @fs.rmdir(base, recursive=true))
    body(base)
  }
}

///|
async test "native mkdir is idempotent and rejects files and file parents" {
  with_atomic_test_dir(async fn(base) {
    let fs = NativeWorkspaceFs()
    for recursive in [false, true] {
      let dir = base + (if recursive { "/nested/dir" } else { "/dir" })
      fs.mkdir(dir, recursive~)
      fs.mkdir(dir, recursive~)
      assert_true(fs.kind(dir, follow_symlink=true) is Dir)
    }
    fs.write_file(base + "/file", "unchanged")
    for path in [base + "/file", base + "/file/child"] {
      let result = try {
        fs.mkdir(path, recursive=true)
        "unexpected success"
      } catch {
        WorkspaceFsError(detail) => detail
      }
      assert_eq(result, "mkdir failed")
    }
    assert_eq(fs.read_file(base + "/file"), "unchanged")
  })
}

///|
async test "native atomic write skips stale files and symlinks without touching them" {
  with_atomic_test_dir(async fn(base) {
    let fs = NativeWorkspaceFs()
    let path = base + "/credential"
    let attempts = Ref(0)
    let stale = "\{path}.tmp-1"
    let link = "\{path}.tmp-2"
    let victim = base + "/victim"
    fs.write_file(stale, "stale-long-content")
    fs.write_file(victim, "victim-unchanged")
    @fs.symlink(target=victim, link)
    fs.write_file(path, "old-long-destination")
    // Local candidates make both collisions deterministic even when other
    // tests perform atomic writes concurrently.
    native_write_file_atomic(path, "new", next_candidate=fn(path) {
      attempts.val += 1
      "\{path}.tmp-\{attempts.val}"
    })
    assert_eq(attempts.val, 3)
    assert_eq(fs.read_file(path), "new")
    assert_eq(fs.read_file(stale), "stale-long-content")
    assert_eq(fs.read_file(victim), "victim-unchanged")
    assert_true(fs.kind(link, follow_symlink=false) is Symlink)
    assert_eq(@fs.file_size(path), 3L)
    assert_eq(@fs.readdir(base).length(), 4)
  })
}

///|
async test "native atomic create and replacement have owner-only permissions" {
  if @async.platform is Windows {
    return
  }
  with_atomic_test_dir(async fn(base) {
    let fs = NativeWorkspaceFs()
    let path = base + "/credential"
    fs.write_file_atomic(path, "first")
    let first = @fs.open(path, mode=ReadOnly)
    defer first.close()
    assert_eq(workspace_test_file_mode(first.fd()), 0o600)
    first.close()
    @fs.chmod(path, 0o666)
    fs.write_file_atomic(path, "second")
    let second = @fs.open(path, mode=ReadOnly)
    defer second.close()
    assert_eq(workspace_test_file_mode(second.fd()), 0o600)
    assert_eq(fs.read_file(path), "second")
    assert_eq(@fs.readdir(base), ["credential"])
  })
}

///|
async test "native atomic create failure remains typed and never writes destination" {
  with_atomic_test_dir(async fn(base) {
    let path = base + "/missing/credential"
    let result = try {
      NativeWorkspaceFs().write_file_atomic(path, "raw-secret-fixture")
      "unexpected success"
    } catch {
      WorkspaceFsError(detail) => detail
    }
    assert_eq(result, "write_file_atomic: staging create failed")
    assert_false(result.contains("raw-secret-fixture"))
    assert_eq(@fs.readdir(base), [])
  })
}

///|
async test "native atomic partial write failure closes handle cleans staging and retains destination" {
  with_atomic_test_dir(async fn(base) {
    let fs = NativeWorkspaceFs()
    let path = base + "/credential"
    fs.write_file(path, "old-destination")
    let retained : Array[@fs.File] = []
    let result = try {
      native_write_file_atomic(path, "raw-secret-fixture", write=async fn(
        file,
        text,
      ) {
        retained.push(file)
        file.write("partial-")
        file.close()
        // A real write on a closed handle must fail before any rename.
        file.write(text)
      })
      "unexpected success"
    } catch {
      WorkspaceFsError(detail) => detail
    }
    assert_eq(result, "write_file_atomic: staging write failed")
    assert_false(result.contains("raw-secret-fixture"))
    assert_eq(fs.read_file(path), "old-destination")
    assert_eq(@fs.readdir(base), ["credential"])
    let closed = try {
      retained[0].write("not-written")
      false
    } catch {
      _ => true
    }
    assert_true(closed)
  })
}

///|
async test "native atomic rename failure removes staging and preserves destination directory" {
  with_atomic_test_dir(async fn(base) {
    let fs = NativeWorkspaceFs()
    let path = base + "/credential"
    fs.mkdir(path, recursive=false)
    fs.write_file(path + "/marker", "unchanged")
    let result = try {
      fs.write_file_atomic(path, "raw-secret-fixture")
      "unexpected success"
    } catch {
      WorkspaceFsError(detail) => detail
    }
    assert_eq(result, "write_file_atomic: replace failed")
    assert_false(result.contains("raw-secret-fixture"))
    assert_eq(fs.read_file(path + "/marker"), "unchanged")
    assert_eq(@fs.readdir(base), ["credential"])
  })
}

///|
async test "native atomic complete write replaces longer content without trailing bytes" {
  with_atomic_test_dir(async fn(base) {
    let fs = NativeWorkspaceFs()
    let path = base + "/credential"
    let content = "secret-fixture-💚\n".repeat(65536)
    fs.write_file_atomic(path, content)
    assert_true(fs.read_file(path) == content)
    fs.write_file_atomic(path, "short")
    assert_eq(fs.read_file(path), "short")
    assert_eq(@fs.file_size(path), 5L)
    assert_eq(@fs.readdir(base), ["credential"])
  })
}

///|
async test "native atomic cancellation after partial write closes handle and removes staging" {
  with_atomic_test_dir(async fn(base) {
    let fs = NativeWorkspaceFs()
    let path = base + "/credential"
    fs.write_file(path, "old-destination")
    let entered : @async.Queue[Unit] = @async.Queue(kind=Unbounded)
    let retained : Array[@fs.File] = []
    @async.with_task_group() <| group => {
      let task = group.spawn(
        () => {
          native_write_file_atomic(path, "raw-secret-fixture", write=async fn(
            file,
            _text,
          ) {
            retained.push(file)
            file.write("partial-secret-fixture")
            entered.put(())
            @async.sleep(10000)
          })
        },
        allow_failure=true,
      )
      entered.get()
      task.cancel()
    }
    assert_eq(fs.read_file(path), "old-destination")
    assert_eq(@fs.readdir(base), ["credential"])
    let closed = try {
      retained[0].write("not-written")
      false
    } catch {
      _ => true
    }
    assert_true(closed)
  })
}
