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
      assert_eq(content, "astgrep: missing 'pattern'")
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
    "run", "-p", "fn $NAME($$ARGS) { $$BODY }", "--json=stream", "-l", "ts",
    "--globs", "*.ts", "src",
  ])
}

///|
test "astgrep_build_args_minimal" {
  assert_eq(build_astgrep_args("foo($$$A)", None, None, None), [
    "run", "-p", "foo($$A)", "--json=stream",
  ])
}

///|
test "astgrep_build_args_lang_before_glob_and_empty_path_omitted" {
  assert_eq(build_astgrep_args("p", Some("py"), Some(""), Some("*.py")), [
    "run", "-p", "p", "--json=stream", "-l", "py", "--globs", "*.py",
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
      assert_eq(content, "(no matches)")
      match structured {
        Some(Object(meta)) => {
          assert_true(meta.get("summary") is Some(String("0 matches")))
          assert_true(meta.get("count") is Some(Number(0.0, ..)))
          assert_true(meta.get("returned") is Some(Number(0.0, ..)))
          assert_true(meta.get("truncated") is Some(False))
        }
        _ => fail("expected structured count: 0 for zero matches")
      }
    }
    other => fail("expected Success for zero matches, got " + other.to_string())
  }
  // Default base "." is ast-grep's own default, so no positional path.
  assert_eq(fake.received[0], ["run", "-p", "foo($$A)", "--json=stream"])
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
      assert_true(content.contains("exit=2"))
      assert_true(content.contains("error: pattern parse failed"))
    }
    other =>
      fail(
        "expected ToolReportedError for nonzero exit, got " + other.to_string(),
      )
  }
}

///|
async test "astgrep_json_stream_renders_compact_file_line_excerpts" {
  let stdout =
    "{\"text\":\"foo(1)\",\"range\":{\"start\":{\"line\":2,\"column\":1}},\"file\":\"src/a.ts\"}\n" +
    "{\"text\":\"foo(2)\\n  .bar()\",\"range\":{\"start\":{\"line\":6,\"column\":0}},\"file\":\"src/b.ts\"}\n"
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
      assert_eq(content, "src/a.ts\n3|foo(1)\nsrc/b.ts\n7|foo(2)   .bar()")
      match structured {
        Some(Object(meta)) => {
          assert_true(meta.get("count") is Some(Number(2.0, ..)))
          assert_true(meta.get("returned") is Some(Number(2.0, ..)))
          assert_true(meta.get("truncated") is Some(False))
        }
        _ => fail("expected compact structured payload")
      }
    }
    other => fail("expected compact Success, got " + other.to_string())
  }
}

///|
async test "astgrep_max_matches_caps_results_with_short_footer" {
  let stdout =
    "{\"text\":\"a()\",\"range\":{\"start\":{\"line\":0}},\"file\":\"a.ts\"}\n" +
    "{\"text\":\"b()\",\"range\":{\"start\":{\"line\":1}},\"file\":\"b.ts\"}\n" +
    "{\"text\":\"c()\",\"range\":{\"start\":{\"line\":2}},\"file\":\"c.ts\"}\n"
  let fake : FakeAstGrepSpawn = {
    results: [(0, stdout, "")],
    index: 0,
    received: [],
  }
  let outcome = execute_astgrep_impl(
    fake,
    None,
    astgrep_call_fields([
      ("pattern", Json::string("$A()")),
      ("max_matches", Json::number(2.0)),
    ]),
  )
  match outcome {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_true(content.contains("a.ts\n1|a()"))
      assert_true(content.contains("b.ts\n2|b()"))
      assert_false(content.contains("c.ts"))
      assert_true(content.has_suffix("… +1 matches"))
      match structured {
        Some(Object(meta)) => {
          assert_true(meta.get("count") is Some(Number(3.0, ..)))
          assert_true(meta.get("returned") is Some(Number(2.0, ..)))
          assert_true(meta.get("truncated") is Some(True))
        }
        _ => fail("expected truncation metadata")
      }
    }
    other => fail("expected capped Success, got " + other.to_string())
  }
}

///|
test "astgrep_unexpected_json_falls_back_to_bounded_raw" {
  let raw = "RAW-HEAD-" + "x".repeat(ASTGREP_OUTPUT_BYTE_CAP + 500) + "-TAIL"
  match render_astgrep_result(0, raw, "", ".", 100) {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_true(content.has_prefix("RAW-HEAD-"))
      assert_true(content.contains("…[cut]"))
      assert_true(structured is None)
      assert_true(content.length() < raw.length())
    }
    _ => fail("unexpected raw output should remain a bounded success")
  }
}

///|
test "astgrep_error_detail_is_bounded" {
  let detail = "ERR-" + "x".repeat(ASTGREP_ERROR_CHAR_CAP + 500)
  match render_astgrep_result(2, "", detail, "src", 100) {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.has_prefix("astgrep exit=2 path=src\nERR-"))
      assert_true(content.contains("…[cut]"))
      assert_true(content.length() < detail.length() + 100)
    }
    _ => fail("expected bounded ToolReportedError")
  }
}

///|
async test "astgrep_anchored_base_resolves_into_positional_path" {
  let anchor = @devkit.WorkspaceAnchor::WorkspaceAnchor("/tmp/ws")
  let fake : FakeAstGrepSpawn = {
    results: [(
      0,
      "{\"text\":\"hit\",\"range\":{\"start\":{\"line\":0}},\"file\":\"src/a.ts\"}\n",
      "",
    )],
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
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_eq(content, "src/a.ts\n1|hit")
    other =>
      fail("expected anchored astgrep to succeed, got " + other.to_string())
  }
  assert_eq(fake.received[0], [
    "run", "-p", "foo($$A)", "--json=stream", "/tmp/ws/src",
  ])
}


///|
test "astgrep_max_matches_must_be_positive_integer" {
  for value in [Json::number(0.0), Json::number(-1.0), Json::string("10")] {
    match extract_astgrep_args(
      Json::object(
        Map::from_array([
          ("pattern", Json::string("$A")),
          ("max_matches", value),
        ]),
      ),
    ) {
      Err(message) => assert_true(message.contains("max_matches"))
      Ok(_) => fail("invalid max_matches must be rejected")
    }
  }
}
