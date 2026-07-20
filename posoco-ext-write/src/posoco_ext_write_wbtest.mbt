///|
fn write_call(path : String, content : String) -> @posoco.ToolCall {
  {
    id: "write-test",
    name: "write",
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
        id: "write-path-type",
        name: "write",
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
        id: "write-content-type",
        name: "write",
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
    let outcome = Ok(WriteTools::new().execute("write", call)) catch {
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
async test "write_missing_parent_is_loud_without_os_error" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-write-missing")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let path = dir + "/missing-parent/output.txt"
    let outcome = Ok(
      WriteTools::new().execute("write", write_call(path, "content")),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Err(@posoco.RuntimeError::InvocationFailed(message)) =>
        assert_eq(
          message,
          "write: write failed for '" + diagnostic_path(path) + "'",
        )
      _ => fail("expected a missing parent directory to fail writing")
    }
  }
}

///|
test "write_diagnostic_path_is_bounded_and_single_line" {
  let raw = "line-one\r\n" + "x".repeat(200) + "TAIL_SECRET"
  let safe = diagnostic_path(raw)
  assert_false(safe.contains("\n"))
  assert_false(safe.contains("\r"))
  assert_true(safe.contains("..."))
  assert_false(safe.contains("TAIL_SECRET"))
}
