///|
fn glob_call(pattern : String, path : Json?) -> @posoco.ToolCall {
  let fields : Array[(String, Json)] = [("pattern", Json::string(pattern))]
  match path {
    Some(value) => fields.push(("path", value))
    None => ()
  }
  glob_call_fields(fields)
}

///|
fn glob_call_fields(fields : Array[(String, Json)]) -> @posoco.ToolCall {
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

///|
/// Anchored glob scans the resolved base and returns base-relative results,
/// so the workspace root never appears in the output.
async test "glob_anchored_base_resolves_and_stays_base_relative" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-glob-anchor")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.write_file(dir + "/a.txt", "x", create_mode=CreateNew)
    @fs.mkdir(dir + "/sub")
    @fs.write_file(dir + "/sub/b.txt", "y", create_mode=CreateNew)
    let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor(dir)
    let tools = GlobTools::GlobTools(anchor=Some(anchor))
    let call : @posoco.ToolCall = {
      call_id: @posoco.CallId::unchecked("glob-anchor"),
      name: @posoco.ToolName::unchecked("glob"),
      arguments: Json::object({ "pattern": Json::string("**/*.txt") }),
    }
    match tools.execute("glob", call) {
      @posoco.ToolOutcome::Success(content~, ..) => {
        assert_true(content.contains("a.txt"))
        assert_true(content.contains("sub/b.txt"))
        assert_false(content.contains(dir))
      }
      _ => fail("expected anchored glob to succeed")
    }
    // An explicit subdirectory base keeps results relative to that base.
    let sub_call : @posoco.ToolCall = {
      call_id: @posoco.CallId::unchecked("glob-anchor-sub"),
      name: @posoco.ToolName::unchecked("glob"),
      arguments: Json::object({
        "pattern": Json::string("*.txt"),
        "path": Json::string("sub"),
      }),
    }
    match tools.execute("glob", sub_call) {
      @posoco.ToolOutcome::Success(content~, ..) => {
        assert_true(content.contains("b.txt"))
        assert_false(content.contains(dir))
      }
      _ => fail("expected anchored sub-base glob to succeed")
    }
  }
}

///|
async test "glob_limit_caps_output_with_footer" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-glob-limit")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.write_file("\{dir}/a.mbt", "// a\n", create_mode=CreateNew)
    @fs.write_file("\{dir}/b.mbt", "// b\n", create_mode=CreateNew)
    @fs.write_file("\{dir}/c.mbt", "// c\n", create_mode=CreateNew)
    let result = GlobTools::GlobTools().execute(
      "glob",
      glob_call_fields([
        ("pattern", Json::string("*.mbt")),
        ("path", Json::string(dir)),
        ("limit", Json::number(2.0)),
      ]),
    )
    match result {
      Success(content~, structured~) => {
        assert_true(content.has_prefix("Found 3 files:\n"))
        assert_true(
          content.contains(
            "… 1 more files; narrow the pattern or raise limit",
          ),
        )
        // Header counts the total; body lists only the capped two.
        assert_eq(content.split("\n").to_array().length(), 5)
        match structured {
          Some(Object(meta)) => {
            assert_true(meta.get("count") is Some(Number(3.0, ..)))
            assert_true(meta.get("truncated") is Some(Json::True))
          }
          _ => fail("expected truncated structured payload")
        }
      }
      other =>
        fail("expected Success for capped glob, got " + other.to_string())
    }
  }
}

///|
async test "glob_limit_wrong_type_and_value_are_loud" {
  let cases : Array[Json] = [
    Json::boolean(true),
    Json::number(0.0),
    Json::number(-3.0),
  ]
  for value in cases {
    let outcome = Ok(
      GlobTools::GlobTools().execute(
        "glob",
        glob_call_fields([("pattern", Json::string("*.mbt")), ("limit", value)]),
      ),
    ) catch {
      error => Err(error)
    }
    match outcome {
      Err(@posoco.RuntimeError::UnknownTool(message)) =>
        assert_true(message.contains("limit"))
      _ => fail("expected invalid limit to be rejected")
    }
  }
}

///|
async test "glob_returns_files_only_and_prunes_ignores_and_hidden" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-glob-prune")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.write_file("\{dir}/top.mbt", "// top\n", create_mode=CreateNew)
    @fs.mkdir("\{dir}/sub")
    @fs.write_file("\{dir}/sub/nested.mbt", "// n\n", create_mode=CreateNew)
    @fs.mkdir("\{dir}/node_modules")
    @fs.write_file(
      "\{dir}/node_modules/dep.mbt",
      "// dep\n",
      create_mode=CreateNew,
    )
    @fs.mkdir("\{dir}/.hidden")
    @fs.write_file("\{dir}/.hidden/x.mbt", "// x\n", create_mode=CreateNew)
    let result = GlobTools::GlobTools().execute(
      "glob",
      glob_call_fields([
        ("pattern", Json::string("**/*.mbt")),
        ("path", Json::string(dir)),
      ]),
    )
    match result {
      Success(content~, structured~) => {
        assert_true(content.contains("\{dir}/top.mbt"))
        assert_true(content.contains("\{dir}/sub/nested.mbt"))
        assert_false(content.contains("node_modules"))
        assert_false(content.contains(".hidden"))
        match structured {
          Some(Object(meta)) =>
            assert_true(meta.get("count") is Some(Number(2.0, ..)))
          _ => fail("expected exactly two matches after pruning")
        }
      }
      other =>
        fail("expected Success for pruned glob, got " + other.to_string())
    }
  }
}

///|
async test "glob_directory_pattern_yields_no_results" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-glob-dironly")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.mkdir("\{dir}/sub")
    @fs.write_file("\{dir}/sub/keep.txt", "x", create_mode=CreateNew)
    let result = GlobTools::GlobTools().execute(
      "glob",
      glob_call_fields([
        ("pattern", Json::string("sub")),
        ("path", Json::string(dir)),
      ]),
    )
    match result {
      Success(content~, structured~) => {
        assert_eq(content, "Found 0 files:\n")
        match structured {
          Some(Object(meta)) =>
            assert_true(meta.get("summary") is Some(String("no files")))
          _ => fail("expected no-files payload for directory-only match")
        }
      }
      other =>
        fail(
          "expected Success without directory entries, got " + other.to_string(),
        )
    }
  }
}

///|
async test "glob_sorts_newest_first" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="posoco-glob-mtime")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(dir, recursive=true))
    }
    @fs.write_file("\{dir}/older.mbt", "// older\n", create_mode=CreateNew)
    @async.sleep(60)
    @fs.write_file("\{dir}/newer.mbt", "// newer\n", create_mode=CreateNew)
    let result = GlobTools::GlobTools().execute(
      "glob",
      glob_call_fields([
        ("pattern", Json::string("*.mbt")),
        ("path", Json::string(dir)),
      ]),
    )
    match result {
      Success(content~, ..) => {
        let newer_at = content.find("\{dir}/newer.mbt")
        let older_at = content.find("\{dir}/older.mbt")
        match (newer_at, older_at) {
          (Some(n), Some(o)) => assert_true(n < o)
          _ => fail("expected both files listed once each")
        }
      }
      other =>
        fail("expected Success for mtime-sorted glob, got " + other.to_string())
    }
  }
}
