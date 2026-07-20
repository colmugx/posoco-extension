///|
fn read_call(path : String) -> @posoco.ToolCall {
  {
    id: "read-test",
    name: "read",
    arguments: Json::object(Map::from_array([("path", Json::string(path))])),
  }
}

///|
async test "read_wrong_type_path_is_not_reported_as_missing" {
  let call : @posoco.ToolCall = {
    id: "read-wrong-type",
    name: "read",
    arguments: Json::object(Map::from_array([("path", Json::number(1.0))])),
  }
  let outcome = Ok(ReadTools::new().execute("read", call)) catch {
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
async test "read_directory_is_loud_without_os_error" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-directory")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let outcome = Ok(ReadTools::new().execute("read", read_call(dir))) catch {
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
async test "read_invalid_utf8_is_explicit_decode_failure" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-read-decode")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/invalid.bin"
    @fs.write_file(path, b"\xff", create_mode=CreateNew)
    let outcome = Ok(ReadTools::new().execute("read", read_call(path))) catch {
      error => Err(error)
    }
    match outcome {
      Err(@posoco.RuntimeError::InvocationFailed(message)) =>
        assert_eq(
          message,
          "read: decode failed for '" + @devkit.sanitize_path(path) + "'",
        )
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
