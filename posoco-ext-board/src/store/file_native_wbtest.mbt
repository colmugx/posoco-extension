///|
test "native empty root stays relative to the current workspace" {
  let store = FileBoardStore::FileBoardStore(root="")
  assert_eq(store.directory, "./.cetas/board/default")
  assert_eq(store.directory, FileBoardStore::FileBoardStore(root=".").directory)
  assert_eq(store.directory, FileBoardStore::FileBoardStore().directory)
}

///|
async test "native absent directory rev0 default path and real durable replacement" {
  let root = @fs.tmpdir(prefix="board-s3b1-")
  defer @fs.rmdir(root, recursive=true)
  let data = root + "/.cetas/board/default"
  let path = root
  let store = FileBoardStore::FileBoardStore(root=path)
  assert_eq(
    FileBoardStore::FileBoardStore().directory,
    "./.cetas/board/default",
  )
  assert_eq(store.load().map(loaded => loaded.snapshot), Ok(empty_snapshot()))
  assert_false(@fs.exists(data))
  assert_eq(store.persist(fixture(), all_events()), Ok(()))
  assert_true(@fs.exists(data + "/board.json"))
  assert_false(@fs.exists(data + "/board.json.tmp"))
  let restarted = FileBoardStore::FileBoardStore(root=path)
  assert_eq(restarted.load().map(loaded => loaded.snapshot), Ok(fixture()))
  assert_eq(
    decode_journal_events(@fs.read_file(data + "/events.jsonl").text()),
    Ok(all_events()),
  )
  let next = { ..fixture(), revision: 18L, }
  assert_eq(store.persist(next, []), Ok(()))
  assert_eq(restarted.load().map(loaded => loaded.snapshot), Ok(next))
  assert_eq(
    decode_journal_events(@fs.read_file(data + "/events.jsonl").text()),
    Ok(all_events()),
  )
  let result = restarted.load().map(loaded => loaded.snapshot).unwrap()
  result.tasks[0].definition_of_done.clear()
  result.tasks.clear()
  result.attempts.clear()
  assert_eq(restarted.load().map(loaded => loaded.snapshot), Ok(next))
}

///|
async test "six injected native stages preserve old board before rename and never replay journal ahead" {
  for
    stage in [
      TempWrite,
      TempFsync,
      JournalAppend,
      JournalFsync,
      Rename,
      DirectoryFsync,
    ] {
    let root = @fs.tmpdir(prefix="board-s3b1-failure-")
    defer @fs.rmdir(root, recursive=true)
    let data = root + "/.cetas/board/default"
    let good = FileBoardStore::FileBoardStore(root~)
    let old = fixture()
    let old_events = [all_events()[0]]
    assert_eq(good.persist(old, old_events), Ok(()))
    let old_bytes = @fs.read_file(data + "/board.json").binary()
    let next = {
      ..old,
      revision: 18L,
      tasks: [
        @domain.BoardTask::from_record(
          id=old.tasks[0].id,
          title="new authoritative title",
          description=old.tasks[0].description,
          stage=old.tasks[0].stage,
          priority=old.tasks[0].priority,
          definition_of_done=old.tasks[0].definition_of_done,
          dependencies=old.tasks[0].dependencies,
          created_at_ms=old.tasks[0].created_at_ms,
          updated_at_ms=old.tasks[0].updated_at_ms,
          ready_since_ms=old.tasks[0].ready_since_ms,
        ),
        old.tasks[1],
      ],
    }
    let event = all_events()[1]
    @fs.write_file(data + "/board.json.tmp", "stale temp")
    let failing = FileBoardStore::FileBoardStore(root~, fail_at=Some(stage))
    if stage == DirectoryFsync {
      match failing.persist(next, [event]) {
        Err(DurabilityUncertain(_)) => ()
        _ => fail("expected post-rename uncertainty")
      }
    } else {
      assert_eq(failing.persist(next, [event]), Err(Injected(stage)))
    }
    assert_false(@fs.exists(data + "/board.json.tmp"))
    let restarted = FileBoardStore::FileBoardStore(root~)
    if stage == DirectoryFsync {
      assert_eq(restarted.load().map(loaded => loaded.snapshot), Ok(next))
      assert_false(@fs.exists(data + "/board.json.tmp"))
    } else {
      assert_eq(restarted.load().map(loaded => loaded.snapshot), Ok(old))
      assert_eq(@fs.read_file(data + "/board.json").binary(), old_bytes)
    }
    let audit = restarted.load().unwrap().journal
    let expected = records(17L, old_events)
    if stage == JournalFsync || stage == Rename || stage == DirectoryFsync {
      expected.append(records(18L, [event]))
    }
    assert_eq(audit, expected)
    // An ahead audit never changes the loaded revision.
    // A later successful write is still allowed and appends, not replays.
    assert_eq(good.persist(next, [event]), Ok(()))
    assert_eq(restarted.load().map(loaded => loaded.snapshot), Ok(next))
    assert_false(@fs.exists(data + "/board.json.tmp"))
  }
}

///|
async test "native first-write failures no board means empty even with ahead audit and temp" {
  for stage in [TempWrite, TempFsync, JournalAppend, JournalFsync, Rename] {
    let root = @fs.tmpdir(prefix="board-s3b1-new-")
    defer @fs.rmdir(root, recursive=true)
    let path = root + "/new/nested/default"
    let store = FileBoardStore::FileBoardStore(root=path, fail_at=Some(stage))
    assert_eq(store.persist(fixture(), all_events()), Err(Injected(stage)))
    assert_false(@fs.exists(path + "/.cetas/board/default/board.json.tmp"))
    let retry = FileBoardStore::FileBoardStore(root=path)
    assert_eq(retry.load().map(loaded => loaded.snapshot), Ok(empty_snapshot()))
    assert_eq(retry.persist(fixture(), []), Ok(()))
    assert_eq(retry.load().map(loaded => loaded.snapshot), Ok(fixture()))
  }
}

///|
async test "native temp residue never rescues absent or corrupt authoritative board" {
  let root = @fs.tmpdir(prefix="board-s3b1-temp-")
  defer @fs.rmdir(root, recursive=true)
  let data = root + "/.cetas/board/default"
  let store = FileBoardStore::FileBoardStore(root~)
  @fs.mkdir(data, recursive=true, allow_exist=true)
  @fs.write_file(data + "/board.json.tmp", encode_snapshot(fixture()).unwrap())
  assert_eq(store.load().map(loaded => loaded.snapshot), Ok(empty_snapshot()))
  @fs.write_file(data + "/board.json", "corrupt")
  invalid(store.load().map(loaded => loaded.snapshot))
  @fs.write_file(data + "/board.json", "")
  invalid(store.load().map(loaded => loaded.snapshot))
  @fs.write_file(data + "/board.json", "null")
  invalid(store.load().map(loaded => loaded.snapshot))
  @fs.write_file(data + "/board.json", b"\xff")
  invalid(store.load().map(loaded => loaded.snapshot))
  @fs.write_file(data + "/board.json", b"\xef\xbb\xbf{}")
  invalid(store.load().map(loaded => loaded.snapshot))
  assert_eq(store.persist(fixture(), []), Ok(()))
  assert_eq(store.load().map(loaded => loaded.snapshot), Ok(fixture()))
}

///|
async test "native malformed complete journal lines fail load and persist before replacement" {
  let root = @fs.tmpdir(prefix="board-s3b1-corrupt-")
  defer @fs.rmdir(root, recursive=true)
  let data = root + "/.cetas/board/default"
  let store = FileBoardStore::FileBoardStore(root~)
  assert_eq(store.persist(fixture(), []), Ok(()))
  let board = @fs.read_file(data + "/board.json").binary()
  let line = journal_line(all_events()[0]).unwrap() + "\n"
  for
    corrupt in [
      "{\n",
      "{}\n",
      "\n",
      line + "broken\n",
      "broken\n" + line,
      line + "\n",
    ] {
    @fs.write_file(data + "/events.jsonl", corrupt)
    invalid(store.load().map(loaded => loaded.snapshot))
    invalid(store.persist({ ..fixture(), revision: 18L, }, all_events()))
    assert_eq(@fs.read_file(data + "/board.json").binary(), board)
    assert_eq(@fs.read_file(data + "/events.jsonl").text(), corrupt)
  }
  @fs.write_file(data + "/events.jsonl", b"\xff\n")
  invalid(store.load().map(loaded => loaded.snapshot))
  invalid(store.persist(fixture(), []))
  assert_eq(@fs.read_file(data + "/board.json").binary(), board)
}

///|
async test "native safely truncates torn tails before append including UTF8 residue" {
  let root = @fs.tmpdir(prefix="board-s3b1-tail-")
  defer @fs.rmdir(root, recursive=true)
  let data = root + "/.cetas/board/default"
  let store = FileBoardStore::FileBoardStore(root~)
  @fs.mkdir(data, recursive=true, allow_exist=true)
  let event = @domain.TaskCreated(id=tid("λ"), at_ms=1L)
  let next = all_events()[1]
  let line = journal_line(event).unwrap() + "\n"
  for
    residue in [
      @utf8.encode("{\"id\":"),
      @utf8.encode("bad\nlast"),
      b"\xe4\xb8",
    ] {
    // A malformed *earlier* physical line still fails, even if final tail is
    // unterminated. Everything else is removed before the next append.
    @fs.write_file(data + "/events.jsonl", @utf8.encode(line) + residue)
    if residue == @utf8.encode("bad\nlast") {
      invalid(store.load().map(loaded => loaded.snapshot))
      invalid(store.persist(fixture(), [next]))
    } else {
      assert_eq(
        store.load().map(loaded => loaded.snapshot),
        Ok(empty_snapshot()),
      )
      assert_eq(store.persist(fixture(), [next]), Ok(()))
      assert_eq(
        @fs.read_file(data + "/events.jsonl").text(),
        line + journal_line(next).unwrap() + "\n",
      )
      assert_eq(store.load().map(loaded => loaded.snapshot), Ok(fixture()))
      assert_eq(store.persist({ ..fixture(), revision: 18L, }, [event]), Ok(()))
      assert_eq(
        decode_journal_events(@fs.read_file(data + "/events.jsonl").text()),
        Ok([event, next, event]),
      )
      @fs.remove(data + "/board.json")
    }
  }
}

///|
async test "native retains valid unterminated records and inserts newline before appending" {
  let root = @fs.tmpdir(prefix="board-s3b1-line-")
  defer @fs.rmdir(root, recursive=true)
  let data = root + "/.cetas/board/default"
  let store = FileBoardStore::FileBoardStore(root~)
  @fs.mkdir(data, recursive=true, allow_exist=true)
  let first = all_events()[0]
  let second = all_events()[1]
  let raw = journal_line(first).unwrap()
  @fs.write_file(data + "/events.jsonl", raw)
  assert_eq(store.load().map(loaded => loaded.snapshot), Ok(empty_snapshot()))
  assert_eq(store.persist(fixture(), [second]), Ok(()))
  assert_eq(
    @fs.read_file(data + "/events.jsonl").text(),
    raw + "\n" + journal_line(second).unwrap() + "\n",
  )
  assert_eq(
    decode_journal_events(@fs.read_file(data + "/events.jsonl").text()),
    Ok([first, second]),
  )
  @fs.write_file(data + "/events.jsonl", raw)
  assert_eq(store.persist(fixture(), []), Ok(()))
  assert_eq(@fs.read_file(data + "/events.jsonl").text(), raw + "\n")
}

///|
async test "native failed persist retries retain a valid unterminated journal tail" {
  for stage in [JournalAppend, Rename] {
    let root = @fs.tmpdir(prefix="board-s3b1-tail-retry-")
    defer @fs.rmdir(root, recursive=true)
    let data = root + "/.cetas/board/default"
    let store = FileBoardStore::FileBoardStore(root~)
    assert_eq(store.persist(fixture(), []), Ok(()))
    let old_board = @fs.read_file(data + "/board.json").binary()
    let first = all_events()[0]
    let second = all_events()[1]
    let raw = journal_line(first).unwrap()
    @fs.write_file(data + "/events.jsonl", raw)
    let next = { ..fixture(), revision: 18L, }
    let failing = FileBoardStore::FileBoardStore(root~, fail_at=Some(stage))
    assert_eq(failing.persist(next, [second]), Err(Injected(stage)))
    assert_eq(@fs.read_file(data + "/board.json").binary(), old_board)
    assert_false(@fs.exists(data + "/board.json.tmp"))
    let appended = raw +
      "\n" +
      journal_line(second, revision=18L).unwrap() +
      "\n"
    let expected = records(17L, [first])
    if stage == JournalAppend {
      // Failure before journal repair preserves the valid unterminated tail.
      assert_eq(@fs.read_file(data + "/events.jsonl").text(), raw)
    } else {
      // Failure after append retains the original record and an ahead fact.
      assert_eq(@fs.read_file(data + "/events.jsonl").text(), appended)
      expected.append(records(18L, [second]))
    }
    assert_eq(store.load(), Ok({ snapshot: fixture(), journal: expected, }))
    assert_eq(store.persist(next, [second]), Ok(()))
    expected.append(records(18L, [second]))
    assert_eq(store.load(), Ok({ snapshot: next, journal: expected, }))
    assert_eq(
      @fs.read_file(data + "/events.jsonl").text(),
      if stage == JournalAppend {
        appended
      } else {
        appended + journal_line(second, revision=18L).unwrap() + "\n"
      },
    )
    assert_false(@fs.exists(data + "/board.json.tmp"))
  }
}

///|
async test "native explicit-time recovery persists before return second restart no repeated normalization" {
  let root = @fs.tmpdir(prefix="board-s3b1-recover-")
  defer @fs.rmdir(root, recursive=true)
  let data = root + "/.cetas/board/default"
  let initial = FileBoardStore::FileBoardStore(root~)
  assert_eq(initial.persist(fixture(), []), Ok(()))
  let first = load_recover_persist(
    FileBoardStore::FileBoardStore(root~),
    at_ms=123L,
  ).unwrap()
  let bytes = @fs.read_file(data + "/board.json").binary()
  let audit = @fs.read_file(data + "/events.jsonl").binary()
  let second = load_recover_persist(
    FileBoardStore::FileBoardStore(root~),
    at_ms=999L,
  ).unwrap()
  assert_eq(first.snapshot.revision, 18L)
  assert_eq(second.snapshot, first.snapshot)
  assert_eq(second.events, [])
  assert_eq(@fs.read_file(data + "/board.json").binary(), bytes)
  assert_eq(@fs.read_file(data + "/events.jsonl").binary(), audit)
  assert_eq(
    decode_journal_events(@fs.read_file(data + "/events.jsonl").text()),
    Ok(first.events),
  )
}

///|
async test "native helper failures never return an unpersisted normalized snapshot" {
  let root = @fs.tmpdir(prefix="board-s3b1-helper-fail-")
  defer @fs.rmdir(root, recursive=true)
  let data = root + "/.cetas/board/default"
  let good = FileBoardStore::FileBoardStore(root~)
  assert_eq(good.persist(fixture(), []), Ok(()))
  let failure = FileBoardStore::FileBoardStore(root~, fail_at=Some(Rename))
  assert_eq(
    load_recover_persist(failure, at_ms=123L).map(_ => ()),
    Err(Injected(Rename)),
  )
  assert_eq(good.load().map(loaded => loaded.snapshot), Ok(fixture()))
  let normalized = load_recover_persist(good, at_ms=456L).unwrap()
  assert_eq(normalized.snapshot.revision, 18L)
  assert_eq(normalized.snapshot.attempts[0].finished_at_ms, Some(456L))
  let second = load_recover_persist(good, at_ms=789L).unwrap()
  assert_eq(second.events, [])
  @fs.write_file(data + "/board.json", "broken")
  invalid(load_recover_persist(good, at_ms=789L))
}

///|
async test "native invalid requests do not create files and real IO errors are typed" {
  let root = @fs.tmpdir(prefix="board-s3b1-io-")
  defer @fs.rmdir(root, recursive=true)
  let path = root + "/absent"
  let store = FileBoardStore::FileBoardStore(root=path)
  invalid(store.persist({ ..fixture(), revision: -1L, }, []))
  invalid(store.persist(fixture(), [@domain.TaskCreated(id=tid(""), at_ms=1L)]))
  assert_false(@fs.exists(path))
  @fs.write_file(path, "not a directory")
  match store.persist(fixture(), []) {
    Err(Io(_)) => ()
    _ => fail("expected typed IO error")
  }
  match store.load().map(loaded => loaded.snapshot) {
    Err(Io(_)) => ()
    _ => fail("expected typed IO error")
  }
}

///|
async test "native request arrays detached before first suspension" {
  let root = @fs.tmpdir(prefix="board-s3b1-detach-")
  defer @fs.rmdir(root, recursive=true)
  let data = root + "/.cetas/board/default"
  let store = FileBoardStore::FileBoardStore(root~)
  let request = fixture()
  let events = all_events()
  let started = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      started.val = true
      assert_eq(store.persist(request, events), Ok(()))
    })
    while !started.val {
      @async.sleep(1)
    }
    request.tasks[0].dependencies.clear()
    request.tasks[0].definition_of_done.clear()
    request.tasks.clear()
    request.attempts.clear()
    match events[2] {
      @domain.DependenciesSet(dependencies~, ..) => dependencies.clear()
      _ => abort("event")
    }
    events.clear()
  })
  assert_eq(store.load().map(loaded => loaded.snapshot), Ok(fixture()))
  assert_eq(
    decode_journal_events(@fs.read_file(data + "/events.jsonl").text()),
    Ok(all_events()),
  )
}

///|
async test "native helper directory fsync failure may already normalize authoritative board" {
  let root = @fs.tmpdir(prefix="board-s3b1-uncertain-")
  defer @fs.rmdir(root, recursive=true)
  let good = FileBoardStore::FileBoardStore(root~)
  assert_eq(good.persist(fixture(), []), Ok(()))
  let failing = FileBoardStore::FileBoardStore(
    root~,
    fail_at=Some(DirectoryFsync),
  )
  match load_recover_persist(failing, at_ms=123L) {
    Err(DurabilityUncertain(_)) => ()
    _ => fail("expected post-rename uncertainty")
  }
  let restart = load_recover_persist(good, at_ms=456L).unwrap()
  assert_eq(restart.snapshot.revision, 18L)
  assert_eq(restart.snapshot.attempts[0].finished_at_ms, Some(123L))
  assert_eq(restart.events, [])
}

///|
test "native parent directory selection for durable recursive creation" {
  for
    (path, expected) in [
      (".cetas/board/default", ".cetas/board"),
      (".cetas", "."),
      ("/a/b", "/a"),
      ("/a", "/"),
      ("/", "/"),
      ("a/b/", "a"),
      ("a/", "."),
    ] {
    assert_eq(parent_directory(path), expected)
  }
}

///|
async test "native and memory expose identical detached snapshot and revisioned journal on success" {
  let root = @fs.tmpdir(prefix="board-s3b1-shared-")
  defer @fs.rmdir(root, recursive=true)
  let file = FileBoardStore::FileBoardStore(root~)
  let memory = MemoryBoardStore::MemoryBoardStore()
  assert_eq(file.load(), memory.load())
  for revision in [17L, 18L, 9007199254740993L] {
    let snapshot = { ..fixture(), revision, }
    assert_eq(file.persist(snapshot, all_events()), Ok(()))
    assert_eq(memory.persist(snapshot, all_events()), Ok(()))
    assert_eq(file.load(), memory.load())
    let loaded = file.load().unwrap()
    assert_eq(loaded.journal[loaded.journal.length() - 1].revision, revision)
    assert_eq(loaded.journal[0].schema_version, 1)
    match loaded.journal[2].event {
      @domain.DependenciesSet(dependencies~, ..) => dependencies.clear()
      _ => abort("event")
    }
    loaded.journal.clear()
    loaded.snapshot.tasks[0].dependencies.clear()
    assert_eq(file.load(), memory.load())
  }
}

///|
async test "native rejects schema-invalid unterminated tail without changing board or journal" {
  let root = @fs.tmpdir(prefix="board-s3b1-schema-tail-")
  defer @fs.rmdir(root, recursive=true)
  let store = FileBoardStore::FileBoardStore(root~)
  let data = root + "/.cetas/board/default"
  assert_eq(store.persist(fixture(), [all_events()[0]]), Ok(()))
  let board = @fs.read_file(data + "/board.json").binary()
  let prefix = @fs.read_file(data + "/events.jsonl").text()
  let line = journal_line(all_events()[1]).unwrap()
  for
    tail in [
      "{}",
      line.replace(old="TaskUpdated", new="Unknown"),
      line.replace(old="\"schema_version\":1", new="\"schema_version\":2"),
    ] {
    let journal = prefix + tail
    @fs.write_file(data + "/events.jsonl", journal)
    invalid(store.load())
    invalid(store.persist({ ..fixture(), revision: 18L, }, all_events()))
    assert_eq(@fs.read_file(data + "/board.json").binary(), board)
    assert_eq(@fs.read_file(data + "/events.jsonl").text(), journal)
    assert_false(@fs.exists(data + "/board.json.tmp"))
  }
}

///|
async test "native best effort cleanup never masks primary IO failure" {
  let root = @fs.tmpdir(prefix="board-s3b1-cleanup-")
  defer @fs.rmdir(root, recursive=true)
  let store = FileBoardStore::FileBoardStore(root~)
  assert_eq(store.persist(fixture(), []), Ok(()))
  let data = root + "/.cetas/board/default"
  let before = @fs.read_file(data + "/board.json").binary()
  // An externally installed directory prevents both opening and unlinking
  // the temp file. Cleanup is best effort and cannot replace the open error.
  @fs.mkdir(data + "/board.json.tmp")
  match store.persist({ ..fixture(), revision: 18L, }, all_events()) {
    Err(Io(message)) => assert_true(message.contains("@fs.open()"))
    _ => fail("expected primary open error")
  }
  assert_eq(@fs.read_file(data + "/board.json").binary(), before)
  assert_eq(store.load().unwrap().snapshot, fixture())
}
