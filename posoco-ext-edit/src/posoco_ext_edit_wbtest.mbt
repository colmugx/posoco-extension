///|
/// Test helpers.

///|
fn edit_call(path : String, replace_all : Json?) -> @posoco.ToolCall {
  edit_call_fields(
    Json::string(path),
    Json::string("old"),
    Json::string("new"),
    replace_all,
  )
}

///|
fn edit_call_fields(
  path : Json,
  old_text : Json,
  new_text : Json,
  replace_all : Json?,
) -> @posoco.ToolCall {
  let fields : Array[(String, Json)] = [
    ("path", path),
    ("old_text", old_text),
    ("new_text", new_text),
  ]
  match replace_all {
    Some(value) => fields.push(("replace_all", value))
    None => ()
  }
  {
    call_id: @posoco.CallId::unchecked("edit-test"),
    name: @posoco.ToolName::unchecked("edit"),
    arguments: Json::object(Map::from_array(fields)),
  }
}

///|
async test "edit_required_fields_distinguish_wrong_type_from_missing" {
  let cases : Array[(@posoco.ToolCall, String)] = [
    (
      edit_call_fields(
        Json::number(1.0),
        Json::string("old"),
        Json::string("new"),
        None,
      ),
      "path",
    ),
    (
      edit_call_fields(
        Json::string("unused"),
        Json::boolean(true),
        Json::string("new"),
        None,
      ),
      "old_text",
    ),
    (
      edit_call_fields(
        Json::string("unused"),
        Json::string("old"),
        Json::array([]),
        None,
      ),
      "new_text",
    ),
  ]
  for pair in cases {
    let (call, field) = pair
    let outcome = Ok(EditTools::EditTools().execute("edit", call)) catch {
      error => Err(error)
    }
    match outcome {
      Err(@posoco.RuntimeError::UnknownTool(message)) => {
        assert_true(message.contains("'" + field + "'"))
        assert_true(message.contains("must be a string"))
        assert_false(message.contains("missing"))
      }
      _ => fail("expected wrong-type edit field to be rejected")
    }
  }
}

///|
test "edit_failure_mappers_cover_stat_decode_and_write" {
  for stage in ["stat", "decode", "write"] {
    match edit_failure(stage, "safe-path") {
      @posoco.RuntimeError::InvocationFailed(message) =>
        assert_eq(message, "edit: " + stage + " failed for 'safe-path'")
      _ => fail("expected edit stage mapping to be InvocationFailed")
    }
  }
}

///|
async test "edit_rejects_malformed_optional_replace_all" {
  let outcome = Ok(
    EditTools::EditTools().execute(
      "edit",
      edit_call("unused", Some(Json::string("yes"))),
    ),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      assert_true(message.contains("replace_all"))
    _ => fail("expected malformed replace_all to be rejected")
  }
}

///|
#cfg(target="native")
async test "edit_directory_is_loud_without_os_error" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-edit-directory")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let outcome = Ok(
      EditTools::EditTools().execute("edit", edit_call(dir, None)),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Err(@posoco.RuntimeError::InvocationFailed(message)) =>
        assert_eq(
          message,
          "edit: read failed for '" + @devkit.sanitize_path(dir) + "'",
        )
      _ => fail("expected editing a directory to fail reading")
    }
  }
}

///|
test "edit_diagnostic_path_is_bounded_and_single_line" {
  let raw = "line-one\t" + "x".repeat(200) + "TAIL_SECRET"
  let safe = @devkit.sanitize_path(raw)
  assert_false(safe.contains("\t"))
  assert_true(safe.contains("..."))
  assert_false(safe.contains("TAIL_SECRET"))
}

///|
/// ——— v2 uniqueness / prefix-strip / freshness tests ———

///|
#cfg(target="native")
async fn run_edit(
  tools : EditTools,
  call : @posoco.ToolCall,
) -> Result[@posoco.ToolOutcome, @posoco.RuntimeError] {
  Ok(tools.execute("edit", call)) catch {
    error => Err(error)
  }
}

///|
#cfg(target="native")
async fn write_file_native(path : String, content : String) -> Unit {
  @fs.write_file(path, content, create_mode=CreateOrTruncate)
}

///|
#cfg(target="native")
fn edit_text_call(
  path : String,
  old : String,
  new : String,
  all : Json?,
) -> @posoco.ToolCall {
  edit_call_fields(
    Json::string(path),
    Json::string(old),
    Json::string(new),
    all,
  )
}

///|
#cfg(target="native")
async test "edit_unique_match_reports_line" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-edit-unique")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/u.txt"
    write_file_native(path, "alpha\nbeta\ngamma\n")
    match
      run_edit(
        EditTools::EditTools(),
        edit_text_call(path, "beta", "BETA", None),
      ) {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) => {
        assert_true(content.contains("replaced 1 occurrence at line 2"))
        let after = @fs.read_file(path).text()
        inspect(after, content="alpha\nBETA\ngamma\n")
      }
      _ => fail("expected unique edit to succeed")
    }
  }
}

///|
#cfg(target="native")
async test "edit_ambiguous_match_lists_lines_and_is_rejected" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-edit-ambig")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/a.txt"
    write_file_native(path, "x\nfoo\ny\nfoo\nz\n")
    match
      run_edit(EditTools::EditTools(), edit_text_call(path, "foo", "bar", None)) {
      Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) => {
        assert_true(content.contains("matches 2 locations"))
        assert_true(content.contains("line(s) 2, 4"))
        assert_true(content.contains("replace_all: true"))
      }
      _ => fail("expected ambiguous edit to be rejected")
    }
  }
}

///|
#cfg(target="native")
async test "edit_replace_all_replaces_every_occurrence" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-edit-all")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/r.txt"
    write_file_native(path, "x\nfoo\ny\nfoo\nz\n")
    match
      run_edit(
        EditTools::EditTools(),
        edit_text_call(path, "foo", "bar", Some(Json::boolean(true))),
      ) {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) =>
        assert_true(content.contains("replaced 2 occurrences"))
      _ => fail("expected replace_all edit to succeed")
    }
    let after = @fs.read_file(path).text()
    inspect(after, content="x\nbar\ny\nbar\nz\n")
  }
}

///|
#cfg(target="native")
async test "edit_not_found_guides_reread" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-edit-miss")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/m.txt"
    write_file_native(path, "alpha\n")
    match
      run_edit(EditTools::EditTools(), edit_text_call(path, "nope", "x", None)) {
      Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) => {
        assert_true(content.contains("old_text not found"))
        assert_true(content.contains("read it again"))
      }
      _ => fail("expected missing old_text to be a reported error")
    }
  }
}

///|
#cfg(target="native")
async test "edit_strips_line_number_prefixes_from_old_text" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-edit-strip")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/p.txt"
    write_file_native(path, "alpha\nbeta\ngamma\n")
    // Verbatim copy of read output: L-prefixed, no exact match raw.
    match
      run_edit(
        EditTools::EditTools(),
        edit_text_call(path, "L2: beta", "BETA", None),
      ) {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) =>
        assert_true(content.contains("line-number prefixes stripped"))
      _ => fail("expected prefixed edit to succeed via stripping")
    }
    let after = @fs.read_file(path).text()
    inspect(after, content="alpha\nBETA\ngamma\n")
  }
}

///|
#cfg(target="native")
async test "edit_freshness_gate_rejects_unread_file" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-edit-unread")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/g.txt"
    write_file_native(path, "alpha\n")
    let ledger = @devkit.FreshnessGuard::FreshnessGuard()
    let tools = EditTools::EditTools(freshness=ledger)
    match run_edit(tools, edit_text_call(path, "alpha", "beta", None)) {
      Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) =>
        assert_true(content.contains("has not been read in this session"))
      _ => fail("expected unread edit to be refused")
    }
  }
}

///|
#cfg(target="native")
async test "edit_fresh_file_succeeds_and_ledger_stays_fresh" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-edit-fresh")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/f.txt"
    write_file_native(path, "alpha\n")
    let ledger = @devkit.FreshnessGuard::FreshnessGuard()
    ledger.note_read(path, FsIo::stat(NativeFsIo::{  }, path))
    let tools = EditTools::EditTools(freshness=ledger)
    match run_edit(tools, edit_text_call(path, "alpha", "beta", None)) {
      Ok(@posoco.ToolOutcome::Success(..)) => ()
      _ => fail("expected fresh edit to succeed")
    }
    // The edit refreshed the stamp: a follow-up edit is not refused.
    let after = FsIo::stat(NativeFsIo::{  }, path)
    debug_inspect(ledger.check(path, Some(after)), content="Fresh")
  }
}

///|
test "edit_policy_is_exclusive" {
  let defs = EditTools::EditTools().list_tools()
  inspect(defs.length(), content="1")
  assert_true(defs[0].policy is @posoco.ExecutionPolicy::Exclusive)
}

///|
/// Anchored edit resolves a relative path against the anchor root and echoes
/// the argument spelling in its result message.
#cfg(target="native")
async test "edit_anchored_relative_path_resolves" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-edit-anchor")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    write_file_native(dir + "/u.txt", "alpha\nbeta\ngamma\n")
    let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(dir)
    let tools = EditTools::EditTools(anchor=Some(anchor))
    match run_edit(tools, edit_text_call("u.txt", "beta", "BETA", None)) {
      Ok(@posoco.ToolOutcome::Success(content~, ..)) => {
        assert_true(content.contains("u.txt"))
        assert_false(content.contains(dir))
        let after = @fs.read_file(dir + "/u.txt").text()
        inspect(after, content="alpha\nBETA\ngamma\n")
      }
      _ => fail("expected anchored edit to succeed")
    }
  }
}
