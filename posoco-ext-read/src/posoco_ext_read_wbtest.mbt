///|
/// ——— Test helpers ———

///|
#cfg(target="native")
fn read_call(path : String) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("read-test"),
    name: @posoco.ToolName::unchecked("read"),
    arguments: Json::object(Map::from_array([("path", Json::string(path))])),
  }
}

///|
#cfg(target="native")
async test "read_wrong_type_path_is_not_reported_as_missing" {
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("read-wrong-type"),
    name: @posoco.ToolName::unchecked("read"),
    arguments: Json::object(Map::from_array([("path", Json::number(1.0))])),
  }
  let outcome = Ok(ReadTools::ReadTools().execute("read", call)) catch {
    error => Err(error)
  }
  match outcome {
    Err(@posoco.RuntimeError::UnknownTool(message)) => {
      assert_true(message.contains("'path'"))
      assert_true(message.contains("must be a string"))
      assert_false(message.contains("missing"))
    }
    _ => fail("expected wrong-type read path to be rejected")
  }
}

///|
test "read_stat_failure_mapping_is_safe_and_explicit" {
  let raw = "stat-line\n" + "x".repeat(200) + "TAIL_SECRET"
  match read_failure("stat", raw) {
    @posoco.RuntimeError::InvocationFailed(message) => {
      assert_true(message.has_prefix("read: stat failed for '"))
      assert_false(message.contains("\n"))
      assert_false(message.contains("TAIL_SECRET"))
    }
    _ => fail("expected stat mapping to be InvocationFailed")
  }
}

///|
#cfg(target="native")
async test "read_directory_is_loud_without_os_error" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-directory")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let outcome = Ok(ReadTools::ReadTools().execute("read", read_call(dir))) catch {
      error => Err(error)
    }
    match outcome {
      Err(@posoco.RuntimeError::InvocationFailed(message)) =>
        assert_eq(
          message,
          "read: read failed for '" + @devkit.sanitize_path(dir) + "'",
        )
      _ => fail("expected reading a directory to fail")
    }
  }
}

///|
#cfg(target="native")
async test "read_invalid_utf8_names_binary_file" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-decode")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/invalid.bin"
    @fs.write_file(path, b"\xff", create_mode=CreateNew)
    let outcome = Ok(ReadTools::ReadTools().execute("read", read_call(path))) catch {
      error => Err(error)
    }
    match outcome {
      Err(@posoco.RuntimeError::InvocationFailed(message)) => {
        assert_true(message.contains("is not valid UTF-8 (binary file)"))
        assert_true(message.contains(@devkit.sanitize_path(path)))
      }
      _ => fail("expected invalid UTF-8 to fail decoding")
    }
  }
}

///|
test "read_sanitize_path_is_bounded_and_single_line" {
  let raw = "line-one\n" + "x".repeat(200) + "TAIL_SECRET"
  let safe = @devkit.sanitize_path(raw)
  assert_false(safe.contains("\n"))
  assert_true(safe.contains("..."))
  assert_false(safe.contains("TAIL_SECRET"))
}

///|
/// ——— v2 paging/formatting tests ———

///|
#cfg(target="native")
fn read_call_args(
  path : String,
  offset? : Int,
  limit? : Int,
) -> @posoco.ToolCall {
  let args : Map[String, Json] = Map::from_array([("path", Json::string(path))])
  match offset {
    Some(n) => args["offset"] = Json::number(n.to_double())
    None => ()
  }
  match limit {
    Some(n) => args["limit"] = Json::number(n.to_double())
    None => ()
  }
  {
    call_id: @posoco.CallId::unchecked("read-test"),
    name: @posoco.ToolName::unchecked("read"),
    arguments: Json::object(args),
  }
}

///|
#cfg(target="native")
async fn run_read(
  tools : ReadTools,
  call : @posoco.ToolCall,
) -> Result[@posoco.ToolOutcome, @posoco.RuntimeError] {
  Ok(tools.execute("read", call)) catch {
    error => Err(error)
  }
}

///|
#cfg(target="native")
async fn write_ten_lines(dir : String) -> String {
  let path = dir + "/ten.txt"
  let content = [ for i in 1..<=10 => "line-\{i}" ].join("\n") + "\n"
  @fs.write_file(path, content, create_mode=CreateNew)
  path
}

///|
#cfg(target="native")
async test "read_pages_with_line_numbers_and_footer" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-page")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = write_ten_lines(dir)
    let outcome = run_read(
      ReadTools::ReadTools(),
      read_call_args(path, limit=3),
    )
    match outcome {
      Ok(@posoco.ToolOutcome::Success(content~, structured~)) => {
        inspect(
          content,
          content="L1: line-1\nL2: line-2\nL3: line-3\n… 7 more lines; call read with offset=4",
        )
        assert_true(structured is Some(_))
      }
      _ => fail("expected paged read to succeed")
    }
  }
}

///|
#cfg(target="native")
async test "read_offset_starts_at_requested_line" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-offset")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = write_ten_lines(dir)
    let outcome = run_read(
      ReadTools::ReadTools(),
      read_call_args(path, offset=4, limit=2),
    )
    match outcome {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) =>
        inspect(
          content,
          content="L4: line-4\nL5: line-5\n… 5 more lines; call read with offset=6",
        )
      _ => fail("expected offset read to succeed")
    }
  }
}

///|
#cfg(target="native")
async test "read_negative_offset_returns_tail_without_footer" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-tail")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = write_ten_lines(dir)
    let outcome = run_read(
      ReadTools::ReadTools(),
      read_call_args(path, offset=-3),
    )
    match outcome {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) =>
        inspect(content, content="L8: line-8\nL9: line-9\nL10: line-10")
      _ => fail("expected tail read to succeed")
    }
  }
}

///|
#cfg(target="native")
async test "read_offset_past_end_names_total_lines" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-past")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = write_ten_lines(dir)
    let outcome = run_read(
      ReadTools::ReadTools(),
      read_call_args(path, offset=99),
    )
    match outcome {
      Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) => {
        assert_true(content.contains("past the end"))
        assert_true(content.contains("10 lines"))
      }
      _ => fail("expected past-end read to be a reported error")
    }
  }
}

///|
#cfg(target="native")
async test "read_empty_file_is_a_notice" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-empty")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/empty.txt"
    @fs.write_file(path, "", create_mode=CreateNew)
    let outcome = run_read(ReadTools::ReadTools(), read_call_args(path))
    match outcome {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) =>
        inspect(content, content="(file exists but is empty)")
      _ => fail("expected empty read to succeed with a notice")
    }
  }
}

///|
#cfg(target="native")
async test "read_truncates_long_lines_with_marker" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-longline")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/long.txt"
    @fs.write_file(path, "a".repeat(3000) + "\n", create_mode=CreateNew)
    let outcome = run_read(ReadTools::ReadTools(), read_call_args(path))
    match outcome {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) => {
        assert_true(content.contains("… (line truncated)"))
        assert_true(content.has_prefix("L1: "))
        assert_false(content.contains("a".repeat(2500)))
      }
      _ => fail("expected long-line read to succeed with truncation")
    }
  }
}

///|
#cfg(target="native")
async test "read_byte_cap_cuts_implicit_page_with_footer" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-bytecap")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/wide.txt"
    let content = [ for _ in 0..<60 => "b".repeat(2500) ].join("\n") + "\n"
    @fs.write_file(path, content, create_mode=CreateNew)
    let outcome = run_read(ReadTools::ReadTools(), read_call_args(path))
    match outcome {
      Ok(@posoco.ToolOutcome::Success(content~, structured~)) => {
        assert_true(content.has_prefix("L1: "))
        assert_true(content.contains("more lines; call read with offset="))
        assert_false(content.contains("L60: "))
        // structured metadata must reflect the cut
        match structured {
          Some(Object(meta)) => assert_true(meta.get("truncated") is Some(True))
          _ => fail("expected structured metadata")
        }
      }
      _ => fail("expected byte-capped read to succeed with a footer")
    }
  }
}

///|
#cfg(target="native")
async test "read_explicit_range_over_byte_cap_is_loud" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-explode")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/wide2.txt"
    let content = [ for _ in 0..<60 => "b".repeat(2500) ].join("\n") + "\n"
    @fs.write_file(path, content, create_mode=CreateNew)
    let outcome = run_read(
      ReadTools::ReadTools(),
      read_call_args(path, limit=60),
    )
    match outcome {
      Err(@posoco.RuntimeError::InvocationFailed(message)) =>
        assert_true(message.contains("exceeds"))
      _ => fail("expected explicit oversized range to raise")
    }
  }
}

///|
#cfg(target="native")
async test "read_rejects_zero_offset_and_nonpositive_limit" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-zero")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = write_ten_lines(dir)
    match run_read(ReadTools::ReadTools(), read_call_args(path, offset=0)) {
      Err(@posoco.RuntimeError::UnknownTool(message)) =>
        assert_true(message.contains("'offset' must be a nonzero"))
      _ => fail("expected zero offset to be rejected")
    }
    match run_read(ReadTools::ReadTools(), read_call_args(path, limit=0)) {
      Err(@posoco.RuntimeError::UnknownTool(message)) =>
        assert_true(message.contains("'limit' must be greater than zero"))
      _ => fail("expected zero limit to be rejected")
    }
  }
}

///|
#cfg(target="native")
async test "read_normalizes_crlf" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-crlf")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/crlf.txt"
    @fs.write_file(path, "alpha\r\nbeta\r\n", create_mode=CreateNew)
    let outcome = run_read(ReadTools::ReadTools(), read_call_args(path))
    match outcome {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) =>
        inspect(content, content="L1: alpha\nL2: beta")
      _ => fail("expected crlf read to succeed")
    }
  }
}

///|
#cfg(target="native")
async test "read_records_freshness_stamp_and_detects_change" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-fresh")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/fresh.txt"
    @fs.write_file(path, "one\ntwo\n", create_mode=CreateNew)
    let ledger = @devkit.FreshnessGuard::FreshnessGuard()
    let tools = ReadTools::ReadTools(freshness=ledger)
    match run_read(tools, read_call_args(path)) {
      Ok(@posoco.ToolOutcome::Success(..)) => ()
      _ => fail("expected guarded read to succeed")
    }
    // Stamp unchanged since the read: fresh.
    let now = FsIo::stat(NativeFsIo::{ }, path)
    debug_inspect(ledger.check(path, Some(now)), content="Fresh")
    // External append changes the stamp: modified.
    @fs.write_file(path, "three\n", append=true)
    let changed = FsIo::stat(NativeFsIo::{ }, path)
    debug_inspect(ledger.check(path, Some(changed)), content="Modified")
  }
}

///|
/// Anchored read resolves a relative path against the anchor root, echoes the
/// argument spelling in the structured output, and records the resolved path
/// as the freshness key so write/edit see the same canonical file identity.
#cfg(target="native")
async test "read_anchored_relative_path_resolves_and_keys_canonically" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-anchor")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let abs = write_ten_lines(dir)
    let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(dir)
    let fresh = @devkit.FreshnessGuard::FreshnessGuard()
    let tools = ReadTools::ReadTools(freshness=fresh, anchor=Some(anchor))
    // Two different relative spellings of the same file must both read it…
    for rel in ["ten.txt", "./ten.txt"] {
      let outcome = run_read(tools, read_call_args(rel))
      match outcome {
        Ok(@posoco.ToolOutcome::Success(content~, structured~)) => {
          assert_true(content.contains("line-1"))
          // …and echo the argument, not the resolved absolute path.
          match structured {
            Some(Json::Object(fields)) =>
              if fields.contains("path") {
                assert_eq(fields["path"], Json::string(rel))
              } else {
                fail("structured output missing path")
              }
            _ => fail("expected structured object")
          }
        }
        _ => fail("expected anchored relative read to succeed")
      }
    }
    // Both spellings collapse to one canonical (resolved) freshness key.
    let stamp = (NativeFsIo::{ } as &FsIo).stat(abs)
    assert_eq(fresh.check(abs, Some(stamp)), @devkit.FreshnessVerdict::Fresh)
    assert_eq(
      fresh.check("ten.txt", Some(stamp)),
      @devkit.FreshnessVerdict::NeverRead,
    )
  }
}

///|
/// ——— delegated fs injection tests ———

///|
/// Minimal `WorkspaceFs` fake serving an in-memory buffer as file content
/// and recording every `read_file` path, so tests can assert the read call
/// reached the injected implementation. Untouched ops raise like a failing
/// backend.
#cfg(target="native")
priv struct FakeDelegatedFs {
  buffer : String
  present : Bool
  reads : Array[String]
}

///|
#cfg(target="native")
fn FakeDelegatedFs::FakeDelegatedFs(
  buffer~ : String,
  present? : Bool = true,
) -> FakeDelegatedFs {
  { buffer, present, reads: [], }
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn exists(self, _path) {
  self.present
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn read_file(self, path) {
  self.reads.push(path)
  self.buffer
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn kind(
  _self,
  _path,
  follow_symlink~,
) {
  abort(
    "FakeDelegatedFs.kind is unavailable (follow_symlink=\{follow_symlink})",
  )
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn write_file(
  _self,
  _path,
  _content,
) {
  abort("FakeDelegatedFs.write_file is unavailable")
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn write_file_atomic(
  _self,
  _path,
  _content,
) {
  abort("FakeDelegatedFs.write_file_atomic is unavailable")
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn remove(_self, _path) {
  abort("FakeDelegatedFs.remove is unavailable")
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn rename(
  _self,
  _from,
  _to_,
  replace~,
) {
  abort("FakeDelegatedFs.rename is unavailable (replace=\{replace})")
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn realpath(_self, _path) {
  abort("FakeDelegatedFs.realpath is unavailable")
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn readdir(
  _self,
  _path,
  include_hidden~,
) {
  abort(
    "FakeDelegatedFs.readdir is unavailable (include_hidden=\{include_hidden})",
  )
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn walk(
  _self,
  _root,
  _callback,
) {
  abort("FakeDelegatedFs.walk is unavailable")
}

///|
#cfg(target="native")
impl @workspace.WorkspaceFs for FakeDelegatedFs with fn mkdir(
  _self,
  _path,
  recursive~,
) {
  abort("FakeDelegatedFs.mkdir is unavailable (recursive=\{recursive})")
}

///|
/// The injected fs owns content: the disk file's bytes are ignored, the
/// shared output contract (line numbers, footer, CRLF normalization, tail)
/// applies unchanged, and every read lands on the injected implementation.
#cfg(target="native")
async test "read_delegated_fs_serves_buffer_and_records_reads" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-delegate")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    // Disk bytes deliberately differ from the injected buffer.
    let path = dir + "/buffer.txt"
    @fs.write_file(path, "disk-content\n", create_mode=CreateNew)
    let fake = FakeDelegatedFs::FakeDelegatedFs(
      buffer=[ for i in 1..<=8 => "buf-\{i}" ].join("\n") +
        "\nbuf-9\r\nbuf-10\n",
    )
    let tools = ReadTools::ReadTools(fs=Some(fake as &@workspace.WorkspaceFs))
    match run_read(tools, read_call_args(path, limit=3)) {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) =>
        inspect(
          content,
          content="L1: buf-1\nL2: buf-2\nL3: buf-3\n… 7 more lines; call read with offset=4",
        )
      _ => fail("expected delegated paged read to succeed")
    }
    match run_read(tools, read_call_args(path, offset=-2)) {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) =>
        inspect(content, content="L9: buf-9\nL10: buf-10")
      _ => fail("expected delegated tail read to succeed")
    }
    assert_eq(fake.reads.length(), 2)
    for p in fake.reads {
      assert_eq(p, path)
    }
  }
}

///|
/// Delegated reads still stamp the local freshness ledger (comparable with
/// write/edit), and a missing file reported by the injected fs stays the
/// recoverable ToolReportedError.
#cfg(target="native")
async test "read_delegated_fs_keeps_local_freshness_and_missing_split" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-delegate-fresh")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/fresh.txt"
    @fs.write_file(path, "one\n", create_mode=CreateNew)
    let ledger = @devkit.FreshnessGuard::FreshnessGuard()
    let fake = FakeDelegatedFs::FakeDelegatedFs(buffer="served\n")
    let tools = ReadTools::ReadTools(
      freshness=ledger,
      fs=Some(fake as &@workspace.WorkspaceFs),
    )
    match run_read(tools, read_call_args(path)) {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) =>
        inspect(content, content="L1: served")
      _ => fail("expected delegated read to succeed")
    }
    let stamp = (NativeFsIo::{ } as &FsIo).stat(path)
    assert_eq(ledger.check(path, Some(stamp)), @devkit.FreshnessVerdict::Fresh)
    // Injected fs reports the file missing: recoverable reported error.
    let absent = FakeDelegatedFs::FakeDelegatedFs(buffer="", present=false)
    let absent_tools = ReadTools::ReadTools(
      fs=Some(absent as &@workspace.WorkspaceFs),
    )
    match run_read(absent_tools, read_call_args(path)) {
      Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) =>
        assert_true(content.contains("File not found"))
      _ => fail("expected missing delegated file to be a reported error")
    }
  }
}
