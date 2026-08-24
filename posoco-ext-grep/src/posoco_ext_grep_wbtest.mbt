///|
fn grep_call(pattern : String, path : String) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("grep-test"),
    name: @posoco.ToolName::unchecked("grep"),
    arguments: Json::object(
      Map::from_array([
        ("pattern", Json::string(pattern)),
        ("path", Json::string(path)),
      ]),
    ),
  }
}

///|
fn grep_call_with_arguments(arguments : Json) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("grep-args"),
    name: @posoco.ToolName::unchecked("grep"),
    arguments,
  }
}

///|
async test "grep_required_pattern_distinguishes_wrong_type_from_missing" {
  let cases : Array[(@posoco.ToolCall, String, Bool)] = [
    (
      grep_call_with_arguments(
        Json::object(Map::from_array([("pattern", Json::boolean(true))])),
      ),
      "must be a string",
      false,
    ),
    (
      grep_call_with_arguments(Json::object(Map::from_array([]))),
      "missing 'pattern'",
      true,
    ),
  ]
  for case in cases {
    let (call, expected, is_missing) = case
    let result = Ok(GrepTools::GrepTools().execute("grep", call)) catch {
      error => Err(error)
    }
    match result {
      Err(@posoco.RuntimeError::UnknownTool(message)) => {
        assert_true(message.contains("pattern"))
        assert_true(message.contains(expected))
        assert_eq(message.contains("missing"), is_missing)
      }
      _ => fail("required grep pattern must be rejected before traversal")
    }
  }
}

///|
async test "grep_wrong_type_optional_path_is_loud" {
  let result = Ok(
    GrepTools::GrepTools().execute(
      "grep",
      grep_call_with_arguments(
        Json::object(
          Map::from_array([
            ("pattern", Json::string("needle")),
            ("path", Json::number(1.0)),
          ]),
        ),
      ),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      assert_true(message.contains("path"))
    _ => fail("wrong-type optional path must not fall back to cwd")
  }
}

///|
async test "grep_wrong_type_optional_glob_is_loud" {
  let result = Ok(
    GrepTools::GrepTools().execute(
      "grep",
      grep_call_with_arguments(
        Json::object(
          Map::from_array([
            ("pattern", Json::string("needle")),
            ("glob", Json::boolean(true)),
          ]),
        ),
      ),
    ),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(message)) =>
      assert_true(message.contains("glob"))
    _ => fail("wrong-type optional glob must not disable filtering")
  }
}

///|
async test "grep_zero_matches_is_success" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-grep-zero")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.write_file(
      "\{dir}/searchable.txt",
      "alpha\nbeta\n",
      create_mode=CreateNew,
    )
    let result = GrepTools::GrepTools().execute(
      "grep",
      grep_call("missing", dir),
    )
    // ToolOutcome is now a variant: Success carries content; business
    // errors are ToolReportedError. Zero matches is still Success.
    match result {
      Success(content~, structured~) => {
        assert_eq(content, "No matches found for: missing")
        match structured {
          Some(Object(meta)) => {
            assert_true(meta.get("summary") is Some(String("no matches")))
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
async test "grep_multi_match_fills_structured_summary" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-grep-multi")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.write_file(
      "\{dir}/hits.txt",
      "needle alpha\nplain\nneedle beta\nneedle gamma\n",
      create_mode=CreateNew,
    )
    let result = GrepTools::GrepTools().execute(
      "grep",
      grep_call("needle", dir),
    )
    match result {
      Success(content~, structured~) => {
        assert_eq(
          content,
          "Found 3 matches:\n\{dir}/hits.txt:1:needle alpha\n\{dir}/hits.txt:3:needle beta\n\{dir}/hits.txt:4:needle gamma\n",
        )
        match structured {
          Some(Object(meta)) => {
            assert_true(meta.get("summary") is Some(String("3 matches")))
            assert_true(meta.get("count") is Some(Number(3.0, ..)))
          }
          _ => fail("expected structured summary payload for multi match")
        }
      }
      other =>
        fail("expected Success for multi match, got " + other.to_string())
    }
  }
}

///|
async test "grep_missing_base_is_loud" {
  let dir = @fs.tmpdir(prefix="posoco-grep-missing")
  @fs.rmdir(dir, recursive=true)
  let result = Ok(
    GrepTools::GrepTools().execute("grep", grep_call("anything", dir)),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::InvocationFailed(message)) => {
      assert_true(message.contains("walk failed"))
      assert_true(message.contains(dir))
    }
    _ => fail("expected missing base to fail traversal")
  }
}

///|
async test "grep_decode_failure_is_loud" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-grep-decode")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.write_file("\{dir}/invalid.bin", b"\xff", create_mode=CreateNew)
    let result = Ok(
      GrepTools::GrepTools().execute("grep", grep_call("anything", dir)),
    ) catch {
      e => Err(e)
    }
    match result {
      Err(@posoco.RuntimeError::InvocationFailed(message)) => {
        assert_true(message.contains("decode failed"))
        assert_true(message.contains("invalid.bin"))
      }
      _ => fail("expected invalid UTF-8 to fail decoding")
    }
  }
}

///|
async test "grep_unreadable_file_is_loud" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-grep-unreadable")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.write_file(
      "\{dir}/unreadable.txt",
      "must not be skipped",
      create_mode=CreateNew,
      permission=0o000,
    )
    let result = Ok(
      GrepTools::GrepTools().execute("grep", grep_call("anything", dir)),
    ) catch {
      e => Err(e)
    }
    match result {
      Err(@posoco.RuntimeError::InvocationFailed(message)) => {
        assert_true(message.contains("read failed"))
        assert_true(message.contains("unreadable.txt"))
      }
      _ => fail("expected unreadable file to fail reading")
    }
  }
}
