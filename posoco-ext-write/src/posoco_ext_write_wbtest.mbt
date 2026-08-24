///|
/// Test helpers.

///|
#cfg(target="native")
fn write_call(path : String, content : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("write-test"),
    name: @posoco.ToolName::unchecked("write"),
    arguments: Json::object(
      Map::from_array([
        ("path", Json::string(path)),
        ("content", Json::string(content)),
      ]),
    ),
  }
}

///|
async test "write_required_fields_distinguish_wrong_type_from_missing" {
  let cases : Array[(@posoco.ToolCall, String)] = [
    (
      {
        call_id: @posoco.CallId::unchecked("write-path-type"),
        name: @posoco.ToolName::unchecked("write"),
        arguments: Json::object(
          Map::from_array([
            ("path", Json::boolean(true)),
            ("content", Json::string("ok")),
          ]),
        ),
      },
      "path",
    ),
    (
      {
        call_id: @posoco.CallId::unchecked("write-content-type"),
        name: @posoco.ToolName::unchecked("write"),
        arguments: Json::object(
          Map::from_array([
            ("path", Json::string("unused")),
            ("content", Json::number(1.0)),
          ]),
        ),
      },
      "content",
    ),
  ]
  for pair in cases {
    let (call, field) = pair
    let outcome = Ok(WriteTools::WriteTools().execute("write", call)) catch {
      error => Err(error)
    }
    match outcome {
      Err(@posoco.RuntimeError::UnknownTool(message)) => {
        assert_true(message.contains("'" + field + "'"))
        assert_true(message.contains("must be a string"))
        assert_false(message.contains("missing"))
      }
      _ => fail("expected wrong-type write field to be rejected")
    }
  }
}

///|
#cfg(target="native")
async test "write_creates_missing_parents" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-write-parents")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/missing-parent/output.txt"
    let outcome = Ok(
      WriteTools::WriteTools().execute("write", write_call(path, "content")),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) => {
        assert_true(content.contains("Wrote 7 bytes"))
        assert_true(@fs.exists(path))
      }
      _ => fail("expected writing with a missing parent to succeed")
    }
  }
}

///|
#cfg(target="native")
async fn run_write(
  tools : WriteTools,
  call : @posoco.ToolCall,
) -> Result[@posoco.ToolOutcome, @posoco.RuntimeError] {
  Ok(tools.execute("write", call)) catch {
    error => Err(error)
  }
}

///|
#cfg(target="native")
async test "write_freshness_gate_rejects_unread_existing_file" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-write-unread")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/target.txt"
    @fs.write_file(path, "old", create_mode=CreateNew)
    let ledger = @devkit.FreshnessGuard::FreshnessGuard()
    let tools = WriteTools::WriteTools(freshness=ledger)
    match run_write(tools, write_call(path, "new")) {
      Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) => {
        assert_true(content.contains("write: refused"))
        assert_true(content.contains("has not been read in this session"))
      }
      _ => fail("expected unread overwrite to be refused")
    }
  }
}

///|
#cfg(target="native")
async test "write_freshness_gate_rejects_modified_file" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-write-modified")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/target.txt"
    @fs.write_file(path, "old", create_mode=CreateNew)
    let ledger = @devkit.FreshnessGuard::FreshnessGuard()
    // A read happened, but the file changed afterwards.
    ledger.note_read(path, @devkit.FileStamp::{
      mtime_s: 1L,
      mtime_ns: 0,
      size: 0L,
    })
    let tools = WriteTools::WriteTools(freshness=ledger)
    match run_write(tools, write_call(path, "new")) {
      Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) =>
        assert_true(content.contains("changed since it was last read"))
      _ => fail("expected stale overwrite to be refused")
    }
  }
}

///|
#cfg(target="native")
async test "write_allows_fresh_file_and_updates_ledger" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-write-fresh")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/target.txt"
    @fs.write_file(path, "old", create_mode=CreateNew)
    let ledger = @devkit.FreshnessGuard::FreshnessGuard()
    ledger.note_read(path, FsIo::stat(NativeFsIo::{  }, path))
    let tools = WriteTools::WriteTools(freshness=ledger)
    match run_write(tools, write_call(path, "new")) {
      Ok(@posoco.ToolOutcome::Success(..)) => ()
      _ => fail("expected fresh overwrite to succeed")
    }
    // The write itself refreshed the stamp, so an immediate follow-up edit
    // is not rejected as externally modified.
    let after = FsIo::stat(NativeFsIo::{  }, path)
    debug_inspect(ledger.check(path, Some(after)), content="Fresh")
  }
}

///|
#cfg(target="native")
async test "write_without_ledger_allows_blind_overwrite" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-write-blind")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/target.txt"
    @fs.write_file(path, "old", create_mode=CreateNew)
    match run_write(WriteTools::WriteTools(), write_call(path, "new")) {
      Ok(@posoco.ToolOutcome::Success(..)) => ()
      _ => fail("expected ledger-less overwrite to succeed")
    }
  }
}

///|
#cfg(target="native")
async test "write_reports_utf8_bytes_not_code_units" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-write-bytes")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/utf8.txt"
    // 5 chars, 6 UTF-8 bytes (é is two bytes).
    match run_write(WriteTools::WriteTools(), write_call(path, "héllo")) {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) =>
        assert_true(content.contains("Wrote 6 bytes"))
      _ => fail("expected utf8 write to succeed")
    }
  }
}

///|
#cfg(target="native")
async test "write_size_cap_is_a_reported_error" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-write-cap")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/big.txt"
    let huge = "x".repeat(1_000_001)
    match run_write(WriteTools::WriteTools(), write_call(path, huge)) {
      Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) => {
        assert_true(
          content.contains("1_000_001 bytes") ||
          content.contains("1000001 bytes"),
        )
        assert_false(@fs.exists(path))
      }
      _ => fail("expected oversized write to be refused")
    }
  }
}

///|
test "write_policy_is_exclusive" {
  let defs = WriteTools::WriteTools().list_tools()
  inspect(defs.length(), content="1")
  assert_true(defs[0].policy is @posoco.ExecutionPolicy::Exclusive)
}

///|
test "write_diagnostic_path_is_bounded_and_single_line" {
  let raw = "line-one\r\n" + "x".repeat(200) + "TAIL_SECRET"
  let safe = @devkit.sanitize_path(raw)
  assert_false(safe.contains("\n"))
  assert_false(safe.contains("\r"))
  assert_true(safe.contains("..."))
  assert_false(safe.contains("TAIL_SECRET"))
}
