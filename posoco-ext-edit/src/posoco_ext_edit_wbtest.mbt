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
    id: "edit-test",
    name: "edit",
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
    let outcome = Ok(EditTools::new().execute("edit", call)) catch {
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
    EditTools::new().execute(
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
async test "edit_directory_is_loud_without_os_error" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-edit-directory")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    let outcome = Ok(EditTools::new().execute("edit", edit_call(dir, None))) catch {
      error => Err(error)
    }
    match outcome {
      Err(@posoco.RuntimeError::InvocationFailed(message)) =>
        assert_eq(
          message,
          "edit: read failed for '" + diagnostic_path(dir) + "'",
        )
      _ => fail("expected editing a directory to fail reading")
    }
  }
}

///|
test "edit_diagnostic_path_is_bounded_and_single_line" {
  let raw = "line-one\t" + "x".repeat(200) + "TAIL_SECRET"
  let safe = diagnostic_path(raw)
  assert_false(safe.contains("\t"))
  assert_true(safe.contains("..."))
  assert_false(safe.contains("TAIL_SECRET"))
}
