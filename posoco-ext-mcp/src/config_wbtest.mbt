///|
/// Whitebox tests for mcp.json discovery, parsing, and the dual-mode bridge.

///|
fn obj(entries : Array[(String, Json)]) -> Json {
  Json::object(Map::from_array(entries))
}

///|
test "parse_stdio_entry_command_args_env" {
  let entry = obj([
    ("command", Json::string("npx")),
    ("args", Json::array([Json::string("-y"), Json::string("server")])),
    ("env", obj([("TOKEN", Json::string("secret-value"))])),
  ])
  match parse_server_entry("github", entry) {
    Ok(config) => {
      assert_eq(config.name, "github")
      match config.transport {
        @transport.AnyTransport::StdioClient(t) => {
          let (cmd, args, extra_env) = stdio_cmd(t)
          assert_eq(cmd, "npx")
          assert_eq(args, ["-y", "server"])
          assert_eq(extra_env.get("TOKEN"), Some("secret-value"))
        }
        other =>
          fail(
            "expected stdio transport for github, got \{other is @transport.AnyTransport::HttpClient(_)}",
          )
      }
    }
    Err(message) => fail("unexpected parse error: " + message)
  }
}

///|
test "parse_http_entry_url" {
  let entry = obj([
    ("type", Json::string("http")),
    ("url", Json::string("http://127.0.0.1:8001/mcp")),
  ])
  match parse_server_entry("db", entry) {
    Ok(config) =>
      match config.transport {
        @transport.AnyTransport::HttpClient(t) =>
          assert_eq(http_url(t), "http://127.0.0.1:8001/mcp")
        other =>
          fail(
            "expected http transport for db, got \{other is @transport.AnyTransport::StdioClient(_)}",
          )
      }
    Err(message) => fail("unexpected parse error: " + message)
  }
}

///|
test "parse_entry_type_mismatch_rejected" {
  // type says http but no url
  let http_no_url = obj([("type", Json::string("http"))])
  match parse_server_entry("a", http_no_url) {
    Ok(_) => fail("expected type/url mismatch failure")
    Err(message) => assert_true(message.contains("needs 'url'"))
  }
  // type says stdio but no command
  let stdio_no_cmd = obj([("type", Json::string("stdio"))])
  match parse_server_entry("a", stdio_no_cmd) {
    Ok(_) => fail("expected type/command mismatch failure")
    Err(message) => assert_true(message.contains("needs 'command'"))
  }
  // unknown type
  let weird_type = obj([
    ("type", Json::string("sse")),
    ("url", Json::string("x")),
  ])
  match parse_server_entry("a", weird_type) {
    Ok(_) => fail("expected unsupported type failure")
    Err(message) => assert_true(message.contains("unsupported type"))
  }
}

///|
test "parse_entry_command_and_url_rejected" {
  let entry = obj([
    ("command", Json::string("npx")),
    ("url", Json::string("http://localhost")),
  ])
  match parse_server_entry("a", entry) {
    Ok(_) => fail("expected both-fields failure")
    Err(message) => assert_true(message.contains("not both"))
  }
}

///|
test "parse_entry_neither_field_rejected" {
  match parse_server_entry("a", obj([])) {
    Ok(_) => fail("expected missing-transport failure")
    Err(message) => assert_true(message.contains("declare 'command'"))
  }
}

///|
test "parse_entry_typed_fields_rejected" {
  let bad_args = obj([
    ("command", Json::string("npx")),
    ("args", Json::string("oops")),
  ])
  match parse_server_entry("a", bad_args) {
    Ok(_) => fail("expected args type failure")
    Err(message) => assert_true(message.contains("'args' must be an array"))
  }
  let bad_env = obj([
    ("command", Json::string("npx")),
    ("env", obj([("K", Json::number(42))])),
  ])
  match parse_server_entry("a", bad_env) {
    Ok(_) => fail("expected env type failure")
    Err(message) =>
      assert_true(message.contains("'env' values must be strings"))
  }
  let bad_name = obj([("command", Json::string("npx"))])
  match parse_server_entry("", bad_name) {
    Ok(_) => fail("expected empty-name failure")
    Err(message) => assert_true(message.contains("name must not be empty"))
  }
}

///|
test "parse_entry_resilience_knobs_parse" {
  let stdio = obj([
    ("command", Json::string("npx")),
    ("timeout_ms", Json::number(5_000)),
    ("max_reconnects", Json::number(3)),
  ])
  match parse_server_entry("s", stdio) {
    Ok(config) => {
      assert_eq(config.timeout_ms, 5_000)
      assert_eq(config.max_reconnects, 3)
    }
    Err(message) => fail("unexpected parse error: " + message)
  }
  let http = obj([
    ("url", Json::string("http://127.0.0.1:8001/mcp")),
    ("timeout_ms", Json::number(60_000)),
    ("max_reconnects", Json::number(5)),
  ])
  match parse_server_entry("h", http) {
    Ok(config) => {
      assert_eq(config.timeout_ms, 60_000)
      assert_eq(config.max_reconnects, 5)
    }
    Err(message) => fail("unexpected parse error: " + message)
  }
}

///|
test "parse_entry_resilience_knobs_zero_disables" {
  let entry = obj([
    ("command", Json::string("npx")),
    ("timeout_ms", Json::number(0)),
    ("max_reconnects", Json::number(0)),
  ])
  match parse_server_entry("a", entry) {
    Ok(config) => {
      assert_eq(config.timeout_ms, 0)
      assert_eq(config.max_reconnects, 0)
    }
    Err(message) => fail("unexpected parse error: " + message)
  }
}

///|
test "parse_entry_resilience_knobs_default_to_constructor" {
  let stdio = obj([("command", Json::string("npx"))])
  match parse_server_entry("s", stdio) {
    Ok(config) => {
      assert_eq(config.timeout_ms, 30_000)
      assert_eq(config.max_reconnects, 1)
    }
    Err(message) => fail("unexpected parse error: " + message)
  }
  let http = obj([("url", Json::string("http://127.0.0.1:8001/mcp"))])
  match parse_server_entry("h", http) {
    Ok(config) => {
      assert_eq(config.timeout_ms, 30_000)
      assert_eq(config.max_reconnects, 1)
    }
    Err(message) => fail("unexpected parse error: " + message)
  }
}

///|
test "parse_entry_resilience_knobs_reject_invalid" {
  let cases : Array[(String, Json, String)] = [
    ("timeout_ms", Json::number(-1), "must not be negative"),
    ("timeout_ms", Json::string("abc"), "must be an integer"),
    ("timeout_ms", Json::number(1.5), "must be an integer"),
    ("timeout_ms", Json::boolean(true), "must be an integer"),
    ("timeout_ms", Json::number(10000000000.0), "out of range"),
    ("max_reconnects", Json::number(-1), "must not be negative"),
    ("max_reconnects", Json::string("abc"), "must be an integer"),
    ("max_reconnects", Json::number(1.5), "must be an integer"),
    ("max_reconnects", Json::boolean(true), "must be an integer"),
  ]
  for case in cases {
    let (field, value, fragment) = case
    let entry = obj([("command", Json::string("npx")), (field, value)])
    match parse_server_entry("a", entry) {
      Ok(_) => fail("expected '\{field}' validation failure")
      Err(message) => {
        assert_true(message.contains(field))
        assert_true(message.contains(fragment))
      }
    }
  }
}

///|
test "parse_entry_legacy_era_tri_state" {
  // absent -> Auto (the modern default; stdio and http alike)
  let stdio_plain = obj([("command", Json::string("npx"))])
  match parse_server_entry("s", stdio_plain) {
    Ok(config) => assert_true(config.era is @client.ProtocolEra::Auto)
    Err(message) => fail("unexpected parse error: " + message)
  }
  let http_plain = obj([("url", Json::string("http://127.0.0.1:8001/mcp"))])
  match parse_server_entry("h", http_plain) {
    Ok(config) => assert_true(config.era is @client.ProtocolEra::Auto)
    Err(message) => fail("unexpected parse error: " + message)
  }
  // true -> Legacy
  let legacy = obj([
    ("command", Json::string("npx")),
    ("legacy", Json::boolean(true)),
  ])
  match parse_server_entry("old", legacy) {
    Ok(config) => assert_true(config.era is @client.ProtocolEra::Legacy)
    Err(message) => fail("unexpected parse error: " + message)
  }
  // false -> Modern
  let modern = obj([
    ("type", Json::string("http")),
    ("url", Json::string("http://127.0.0.1:8001/mcp")),
    ("legacy", Json::boolean(false)),
  ])
  match parse_server_entry("strict", modern) {
    Ok(config) => assert_true(config.era is @client.ProtocolEra::Modern)
    Err(message) => fail("unexpected parse error: " + message)
  }
}

///|
test "parse_entry_legacy_rejects_non_boolean" {
  let cases : Array[Json] = [Json::string("yes"), Json::number(1)]
  for value in cases {
    let entry = obj([("command", Json::string("npx")), ("legacy", value)])
    match parse_server_entry("a", entry) {
      Ok(_) => fail("expected 'legacy' validation failure")
      Err(message) => assert_true(message.contains("must be a boolean"))
    }
  }
}

///|
test "parse_document_shapes" {
  // missing mcpServers -> empty
  match parse_mcp_document(obj([]), "test") {
    Ok(configs) => assert_true(configs.is_empty())
    Err(message) => fail("unexpected error: " + message)
  }
  // mcpServers not an object
  match parse_mcp_document(obj([("mcpServers", Json::array([]))]), "test") {
    Ok(_) => fail("expected mcpServers object failure")
    Err(message) =>
      assert_true(message.contains("mcpServers must be an object"))
  }
  // document not an object
  match parse_mcp_document(Json::array([]), "test") {
    Ok(_) => fail("expected document object failure")
    Err(message) => assert_true(message.contains("must be an object"))
  }
}

///|
fn stdio_config(name : String) -> MCPServerConfig {
  {
    name,
    transport: @transport.AnyTransport::StdioClient(
      @transport.StdioClientTransport::StdioClientTransport(
        cmd="echo",
        args=[],
        extra_env=Map::from_array([]),
      ),
    ),
    auth: ServerAuth::NoAuth,
    era: @client.ProtocolEra::Auto,
    timeout_ms: 30_000,
    max_reconnects: 1,
  }
}

///|
test "merge_project_overrides_user" {
  let user = [stdio_config("shared"), stdio_config("user_only")]
  let project = [stdio_config("shared")] // same name replaces the user entry
  let merged = merge_server_configs(user, project)
  assert_eq(merged.length(), 2)
  assert_eq(merged[0].name, "shared") // stable user-first order
  assert_eq(merged[1].name, "user_only")
}

///|
test "mcp_json_paths_normalize_trailing_slash" {
  assert_eq(project_mcp_json_path("/w"), "/w/.mcp.json")
  assert_eq(project_mcp_json_path("/w/"), "/w/.mcp.json")
  assert_eq(user_mcp_json_path("/home/u"), "/home/u/.cetas/mcp.json")
  assert_eq(user_mcp_json_path("/home/u/"), "/home/u/.cetas/mcp.json")
}

///|
async fn write_config_file(path : String, content : String) -> Unit {
  @fs.write_file(
    path,
    content,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o644,
  ) catch {
    _ => fail("test setup: could not write " + path)
  }
}

///|
async test "discover_reads_and_merges_both_levels" {
  let root = @fs.tmpdir(prefix="posoco-mcp-test")
  let home = root + "/home"
  let cwd = root + "/project"
  @fs.mkdir(home + "/.cetas", recursive=true) catch {
    _ => fail("mkdir home")
  }
  @fs.mkdir(cwd, recursive=true) catch {
    _ => fail("mkdir cwd")
  }
  write_config_file(
    home + "/.cetas/mcp.json",
    "{\"mcpServers\":{\"shared\":{\"url\":\"http://u\"},\"user_only\":{\"url\":\"http://v\"}}}",
  )
  write_config_file(
    cwd + "/.mcp.json",
    "{\"mcpServers\":{\"shared\":{\"command\":\"proj\"}}}",
  )
  match discover_mcp_servers(cwd, home) {
    Ok(configs) => {
      assert_eq(configs.length(), 2)
      assert_eq(configs[0].name, "shared")
      // project entry won: stdio, not http
      assert_true(
        configs[0].transport is @transport.AnyTransport::StdioClient(_),
      )
      assert_eq(configs[1].name, "user_only")
      assert_true(
        configs[1].transport is @transport.AnyTransport::HttpClient(_),
      )
    }
    Err(message) => fail("unexpected discovery error: " + message)
  }
}

///|
async test "discover_missing_files_yield_empty" {
  let root = @fs.tmpdir(prefix="posoco-mcp-test")
  match discover_mcp_servers(root + "/nope", root + "/nohome") {
    Ok(configs) => assert_true(configs.is_empty())
    Err(message) => fail("missing files must not error: " + message)
  }
}

///|
async test "discover_malformed_project_file_fails_loud" {
  let root = @fs.tmpdir(prefix="posoco-mcp-test")
  @fs.mkdir(root + "/p", recursive=true) catch {
    _ => fail("mkdir")
  }
  write_config_file(root + "/p/.mcp.json", "{not json")
  match discover_mcp_servers(root + "/p", root + "/h") {
    Ok(_) => fail("expected malformed mcp.json failure")
    Err(message) => {
      assert_true(message.contains("not valid JSON"))
      assert_true(message.contains("project"))
    }
  }
}

///|
async test "bridge_defaults_and_lazy_activate_without_group" {
  let fresh = MCPToolBridge()
  assert_true(fresh.mode == LoadMode::Eager)
  assert_eq(fresh.catalog_revision, 0)
  let bridge = MCPToolBridge::discover(
    cwd="/nonexistent",
    home="/nonexistent",
    mode=LoadMode::Lazy,
  )
  match bridge {
    Ok(bridge) => {
      assert_true(bridge.mode == LoadMode::Lazy)
      bridge.pending.push(stdio_config("orphan"))
      let failures = bridge.activate()
      assert_true(bridge.activated)
      assert_eq(failures.length(), 1)
      assert_eq(failures[0].0, "orphan")
      assert_true(failures[0].1.contains("task group"))
      assert_eq(bridge.catalog_revision, 1)
    }
    Err(message) => fail("unexpected discovery error: " + message)
  }
}

///|
fn bridge_with_mode(mode : LoadMode) -> MCPToolBridge {
  {
    connections: [],
    tool_to_conn: Map::from_array([]),
    mode,
    pending: [stdio_config("s")],
    group: None,
    activated: false,
    catalog_revision: 0,
    startup_failures: [],
    server_tokens: Map::from_array([]),
    auth_challenges: Map::from_array([]),
    configs: Map::from_array([]),
  }
}

///|
async test "lazy_on_start_activates_eager_on_start_does_not" {
  let lazy_bridge = bridge_with_mode(LoadMode::Lazy)
  lazy_bridge.on_start()
  assert_true(lazy_bridge.activated)
  assert_eq(lazy_bridge.catalog_revision, 1)
  let eager_bridge = bridge_with_mode(LoadMode::Eager)
  eager_bridge.on_start()
  assert_false(eager_bridge.activated)
  assert_eq(eager_bridge.catalog_revision, 0)
}
