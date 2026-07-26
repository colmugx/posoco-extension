///|
fn glob_call(pattern : String, path : Json?) -> @posoco.ToolCall {
  let fields : Array[(String, Json)] = [("pattern", Json::string(pattern))]
  match path {
    Some(value) => fields.push(("path", value))
    None => ()
  }
  {
    id: "glob-test",
    name: "glob",
    arguments: Json::object(Map::from_array(fields)),
  }
}

///|
async test "glob_wrong_type_pattern_is_not_reported_as_missing" {
  let call : @posoco.ToolCall = {
    id: "glob-pattern-type",
    name: "glob",
    arguments: Json::object(Map::from_array([("pattern", Json::boolean(true))])),
  }
  let outcome = Ok(GlobTools::GlobTools().execute("glob", call)) catch {
    error => Err(error)
  }
  match outcome {
    Err(@posoco.RuntimeError::UnknownTool(message)) => {
      assert_true(message.contains("'pattern'"))
      assert_true(message.contains("must be a string"))
      assert_false(message.contains("missing"))
    }
    _ => fail("expected wrong-type glob pattern to be rejected")
  }
}

///|
async test "glob_rejects_malformed_optional_path" {
  let outcome = Ok(
    GlobTools::GlobTools().execute(
      "glob",
      glob_call("*.mbt", Some(Json::number(1.0))),
    ),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      assert_true(message.contains("path"))
    _ => fail("expected malformed optional path to be rejected")
  }
}

///|
/// Native-only: drives `@fs.tmpdir`/`@fs.rmdir` and asserts the native
/// `@fs.walk`-specific failure message. Bun.Glob has different failure modes
/// on js, so this test is skipped there.
#cfg(target="native")
async test "glob_missing_base_is_loud_without_os_error" {
  let dir = @fs.tmpdir(prefix="posoco-glob-missing")
  @fs.rmdir(dir, recursive=true)
  let outcome = Ok(
    GlobTools::GlobTools().execute(
      "glob",
      glob_call("*.mbt", Some(Json::string(dir))),
    ),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(@posoco.RuntimeError::InvocationFailed(message)) =>
      assert_eq(
        message,
        "glob: walk failed for '" + @devkit.sanitize_path(dir) + "'",
      )
    _ => fail("expected a missing base directory to fail traversal")
  }
}

///|
test "glob_diagnostic_path_is_bounded_and_single_line" {
  let raw = "line-one\n" + "x".repeat(200) + "TAIL_SECRET"
  let safe = @devkit.sanitize_path(raw)
  assert_false(safe.contains("\n"))
  assert_true(safe.contains("..."))
  assert_false(safe.contains("TAIL_SECRET"))
}
