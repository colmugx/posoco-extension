///|
fn glob_call(pattern : String, path : Json?) -> @posoco.ToolCall {
  let fields : Array[(String, Json)] = [("pattern", Json::string(pattern))]
  match path {
    Some(value) => fields.push(("path", value))
    None => ()
  }
  {
    call_id: @posoco.CallId::unchecked("glob-test"),
    name: @posoco.ToolName::unchecked("glob"),
    arguments: Json::object(Map::from_array(fields)),
  }
}

///|
async test "glob_wrong_type_pattern_is_not_reported_as_missing" {
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("glob-pattern-type"),
    name: @posoco.ToolName::unchecked("glob"),
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

///|
async test "glob_zero_matches_fills_structured_summary" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-glob-zero")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.write_file("\{dir}/a.mbt", "// a\n", create_mode=CreateNew)
    let result = GlobTools::GlobTools().execute(
      "glob",
      glob_call("**/*.noext", Some(Json::string(dir))),
    )
    match result {
      Success(content~, structured~) => {
        assert_eq(content, "Found 0 files:\n")
        match structured {
          Some(Object(meta)) => {
            assert_true(meta.get("summary") is Some(String("no files")))
            assert_true(meta.get("count") is Some(Number(0.0, ..)))
          }
          _ => fail("expected structured summary payload for zero matches")
        }
      }
      other =>
        fail("expected Success for zero matches, got " + other.to_string())
    }
  }
}

///|
async test "glob_multi_file_fills_structured_summary" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-glob-multi")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.write_file("\{dir}/a.mbt", "// a\n", create_mode=CreateNew)
    @fs.write_file("\{dir}/b.mbt", "// b\n", create_mode=CreateNew)
    @fs.write_file("\{dir}/c.txt", "// c\n", create_mode=CreateNew)
    let result = GlobTools::GlobTools().execute(
      "glob",
      glob_call("**/*.mbt", Some(Json::string(dir))),
    )
    match result {
      Success(content~, structured~) => {
        // Walk order is not alphabetical, so pin the exact shape, not the order.
        assert_true(content.has_prefix("Found 2 files:\n"))
        assert_true(content.contains("\{dir}/a.mbt"))
        assert_true(content.contains("\{dir}/b.mbt"))
        assert_false(content.contains("c.txt"))
        assert_eq(content.split("\n").to_array().length(), 4)
        match structured {
          Some(Object(meta)) => {
            assert_true(meta.get("summary") is Some(String("2 files")))
            assert_true(meta.get("count") is Some(Number(2.0, ..)))
          }
          _ => fail("expected structured summary payload for multi file")
        }
      }
      other => fail("expected Success for multi file, got " + other.to_string())
    }
  }
}
