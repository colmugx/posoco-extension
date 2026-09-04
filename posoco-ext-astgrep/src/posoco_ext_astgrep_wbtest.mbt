///|
fn astgrep_call_with_arguments(arguments : Json) -> @posoco.ToolCall {
  {
    call_id: @posoco.CallId::unchecked("astgrep-test"),
    name: @posoco.ToolName::unchecked("astgrep"),
    arguments,
  }
}

///|
fn astgrep_call_fields(fields : Array[(String, Json)]) -> @posoco.ToolCall {
  astgrep_call_with_arguments(Json::object(Map::from_array(fields)))
}

///|
/// Scripted spawner: plays canned `(exit, stdout, stderr)` results in order
/// and records every argv it was handed, so the shared impl can be tested
/// without an ast-grep binary on the machine.
priv struct FakeAstGrepSpawn {
  results : Array[(Int, String, String)]
  mut index : Int
  received : Array[Array[String]]
}

///|
impl AstGrepSpawn for FakeAstGrepSpawn with fn spawn(
  self : FakeAstGrepSpawn,
  argv : Array[String],
) -> (Int, String, String) raise @posoco.RuntimeError {
  self.received.push(argv)
  let result = self.results[self.index]
  self.index += 1
  result
}

///|
test "astgrep_tooldef_shape" {
  let defs = shared_list_tools()
  assert_eq(defs.length(), 1)
  let def = defs[0]
  assert_eq(def.name.value, "astgrep")
  assert_eq(def.owner.value, "posoco_ext_astgrep")
  assert_eq(def.provenance, Some("posoco_ext_astgrep"))
  match def.policy {
    @posoco.ExecutionPolicy::Parallel => ()
    _ => fail("astgrep is read-only search and must be Parallel")
  }
  match def.input_schema {
    Object(fields) =>
      match fields.get("required") {
        Some(Array(items)) => {
          assert_eq(items.length(), 1)
          assert_true(items[0] is String("pattern"))
        }
        _ => fail("astgrep schema must require exactly 'pattern'")
      }
    _ => fail("astgrep input_schema must be a JSON object")
  }
}

///|
async test "astgrep_missing_pattern_is_tool_reported_error" {
  let result = Ok(
    AstGrepTools::AstGrepTools().execute(
      "astgrep",
      astgrep_call_with_arguments(Json::object(Map::from_array([]))),
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) => {
      assert_true(content.contains("missing 'pattern'"))
      assert_true(content.contains("ast-grep pattern"))
    }
    _ => fail("missing pattern must be a model-visible ToolReportedError")
  }
}

///|
async test "astgrep_wrong_typed_pattern_is_tool_reported_error" {
  let result = Ok(
    AstGrepTools::AstGrepTools().execute(
      "astgrep",
      astgrep_call_with_arguments(
        Json::object(Map::from_array([("pattern", Json::number(1.0))])),
      ),
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Ok(@posoco.ToolOutcome::ToolReportedError(content~, ..)) =>
      assert_true(content.contains("'pattern' must be a string"))
    _ => fail("wrong-typed pattern must be a model-visible ToolReportedError")
  }
}

///|
test "astgrep_build_args_full" {
  let args = build_astgrep_args(
    "fn $NAME($$$ARGS) { $$$BODY }",
    Some("ts"),
    Some("src"),
    Some("*.ts"),
  )
  assert_eq(args, [
    "run", "-p", "fn $NAME($$$ARGS) { $$$BODY }", "-l", "ts", "--globs", "*.ts",
    "src",
  ])
}

///|
test "astgrep_build_args_minimal" {
  assert_eq(build_astgrep_args("foo($$$A)", None, None, None), [
    "run", "-p", "foo($$$A)",
  ])
}

///|
test "astgrep_build_args_lang_before_glob_and_empty_path_omitted" {
  assert_eq(build_astgrep_args("p", Some("py"), Some(""), Some("*.py")), [
    "run", "-p", "p", "-l", "py", "--globs", "*.py",
  ])
}

///|
test "astgrep_missing_binary_error_lists_candidates_and_hint" {
  let message = missing_binary_error(["ast-grep", "sg"])
  assert_true(message.contains("ast-grep"))
  assert_true(message.contains("sg"))
  assert_true(message.contains("brew install"))
}

///|
async test "astgrep_zero_match_exit_zero_is_success" {
  let fake : FakeAstGrepSpawn = {
    results: [(0, "", "")],
    index: 0,
    received: [],
  }
  let outcome = execute_astgrep_impl(
    fake,
    None,
    astgrep_call_fields([("pattern", Json::string("foo($$$A)"))]),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_eq(content, "No matches found for: foo($$$A)")
      match structured {
        Some(Object(meta)) => {
          assert_true(meta.get("summary") is Some(String("no matches")))
          assert_true(meta.get("count") is Some(Number(0.0, ..)))
        }
        _ => fail("expected structured count: 0 for zero matches")
      }
    }
    other => fail("expected Success for zero matches, got " + other.to_string())
  }
  // Default base "." is ast-grep's own default, so no positional path.
  assert_eq(fake.received[0], ["run", "-p", "foo($$$A)"])
}

///|
async test "astgrep_nonzero_exit_reports_stderr_with_sanitized_base" {
  let fake : FakeAstGrepSpawn = {
    results: [(2, "", "error: pattern parse failed\n")],
    index: 0,
    received: [],
  }
  let outcome = execute_astgrep_impl(
    fake,
    None,
    astgrep_call_fields([
      ("pattern", Json::string("bad pattern")),
      ("path", Json::string("/tmp/ws/src")),
    ]),
  )
  match outcome {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("/tmp/ws/src"))
      assert_true(content.contains("exit 2"))
      assert_true(content.contains("error: pattern parse failed"))
    }
    other =>
      fail(
        "expected ToolReportedError for nonzero exit, got " + other.to_string(),
      )
  }
}

///|
async test "astgrep_exit_zero_stdout_passes_through_raw" {
  let stdout = "src/a.ts:3: foo(1)\nsrc/b.ts:7: foo(2)\n"
  let fake : FakeAstGrepSpawn = {
    results: [(0, stdout, "")],
    index: 0,
    received: [],
  }
  let outcome = execute_astgrep_impl(
    fake,
    None,
    astgrep_call_fields([("pattern", Json::string("foo($$$A)"))]),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_eq(content, stdout)
      match structured {
        Some(Object(meta)) =>
          assert_true(meta.get("matches") is Some(String("raw")))
        _ => fail("expected raw passthrough structured payload")
      }
    }
    other => fail("expected Success passthrough, got " + other.to_string())
  }
}

///|
async test "astgrep_anchored_base_resolves_into_positional_path" {
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor("/tmp/ws")
  let fake : FakeAstGrepSpawn = {
    results: [(0, "hit\n", "")],
    index: 0,
    received: [],
  }
  let outcome = execute_astgrep_impl(
    fake,
    Some(anchor),
    astgrep_call_fields([
      ("pattern", Json::string("foo($$$A)")),
      ("path", Json::string("src")),
    ]),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => assert_eq(content, "hit\n")
    other =>
      fail("expected anchored astgrep to succeed, got " + other.to_string())
  }
  assert_eq(fake.received[0], ["run", "-p", "foo($$$A)", "/tmp/ws/src"])
}
