///|
// ServerAuth parsing, runtime token precedence, 401 challenge extraction,
// and reconnect_server. The pure cases run on native and js alike; the e2e
// case reuses the http bearer fixture externs from mcp_js_auth_wbtest.mbt.

///|
test "parse_server_auth accepts oauth and defaults to NoAuth" {
  let oauth : Map[String, Json] = Map::from_array([
    ("auth", Json::string("oauth")),
  ])
  inspect(
    parse_server_auth(oauth, "srv", use_stdio=false) is Ok(ServerAuth::OAuth),
    content="true",
  )
  inspect(
    parse_server_auth(Map::from_array([]), "srv", use_stdio=false)
    is Ok(ServerAuth::NoAuth),
    content="true",
  )
  inspect(
    parse_server_auth(Map::from_array([]), "srv", use_stdio=true)
    is Ok(ServerAuth::NoAuth),
    content="true",
  )
}

///|
test "parse_server_auth rejects invalid values stdio and wrong types" {
  let bad : Map[String, Json] = Map::from_array([
    ("auth", Json::string("basic")),
  ])
  match parse_server_auth(bad, "srv", use_stdio=false) {
    Err(message) => {
      inspect(message.contains("srv"), content="true")
      inspect(message.contains("basic"), content="true")
    }
    Ok(_) => fail("expected invalid auth value failure")
  }
  // stdio entries carry secrets on env; the auth key is rejected outright.
  let stdio : Map[String, Json] = Map::from_array([
    ("auth", Json::string("oauth")),
  ])
  inspect(
    parse_server_auth(stdio, "srv", use_stdio=true) is Err(_),
    content="true",
  )
  let wrong_type : Map[String, Json] = Map::from_array([
    ("auth", Json::number(1.0)),
  ])
  inspect(
    parse_server_auth(wrong_type, "srv", use_stdio=false) is Err(_),
    content="true",
  )
}

///|
test "parse_server_entry carries auth into both transports" {
  let http : Json = @json.parse(
    "{ \"url\": \"http://127.0.0.1:9/mcp\", \"auth\": \"oauth\" }",
  ) catch {
    _ => fail("fixture must parse")
  }
  match parse_server_entry("cloud", http) {
    Ok(config) => inspect(config.auth is ServerAuth::OAuth, content="true")
    Err(message) => fail("parse failed: " + message)
  }
  let stdio : Json = @json.parse(
    "{ \"command\": \"npx\", \"args\": [], \"auth\": \"oauth\" }",
  ) catch {
    _ => fail("fixture must parse")
  }
  inspect(parse_server_entry("local", stdio) is Err(_), content="true")
}

///|
test "effective_http_token prefers runtime then falls back to static" {
  let tokens : Map[String, String] = Map::from_array([("bear", "runtime-token")])
  inspect(
    effective_http_token(tokens, "bear", "static-token"),
    content="runtime-token",
  )
  // Runtime blank or missing never wins.
  inspect(
    effective_http_token(tokens, "other", "static-token"),
    content="static-token",
  )
  let blank : Map[String, String] = Map::from_array([("bear", "")])
  inspect(
    effective_http_token(blank, "bear", "static-token"),
    content="static-token",
  )
  // Double empty: nothing anywhere, the empty string is the honest answer.
  inspect(effective_http_token(tokens, "bear", ""), content="runtime-token")
  inspect(effective_http_token(Map::from_array([]), "bear", ""), content="")
}

///|
test "extract_resource_metadata_uri reads the quoted parameter only" {
  let challenge = "HTTP 401 Unauthorized — WWW-Authenticate: Bearer resource_metadata_uri=\"https://s.example/.well-known/oauth-protected-resource\""
  inspect(
    match extract_resource_metadata_uri(challenge) {
      Some(uri) => uri
      None => "<none>"
    },
    content="https://s.example/.well-known/oauth-protected-resource",
  )
  // Stops at the closing quote; later quotes stay out.
  inspect(
    match
      extract_resource_metadata_uri(
        "Bearer resource_metadata_uri=\"https://a.b/r\" trailing \"x\"",
      ) {
      Some(uri) => uri
      None => "<none>"
    },
    content="https://a.b/r",
  )
  // Bearer with no parameters, or a plain 401: no challenge to extract.
  inspect(
    extract_resource_metadata_uri(
      "HTTP 401 Unauthorized — WWW-Authenticate: Bearer",
    )
    is None,
    content="true",
  )
  inspect(
    extract_resource_metadata_uri("HTTP 401 Unauthorized") is None,
    content="true",
  )
  // Unterminated value: refuse to guess.
  inspect(
    extract_resource_metadata_uri("Bearer resource_metadata_uri=\"https://a.b")
    is None,
    content="true",
  )
}

///|
test "servers_by_auth lists only configs declaring the auth" {
  let cloud : MCPServerConfig = {
    ..http_config("cloud"),
    auth: ServerAuth::OAuth,
  }
  let bridge : MCPToolBridge = {
    connections: [],
    tool_to_conn: Map::from_array([]),
    mode: LoadMode::Lazy,
    pending: [http_config("plain")],
    group: None,
    activated: false,
    catalog_revision: 0,
    startup_failures: [],
    server_tokens: Map::from_array([]),
    auth_challenges: Map::from_array([]),
    configs: Map::from_array([("cloud", cloud), ("plain", http_config("plain"))]),
  }
  let oauth_names = bridge.servers_by_auth(ServerAuth::OAuth)
  inspect(oauth_names.length(), content="1")
  inspect(oauth_names[0], content="cloud")
  let noauth_names = bridge.servers_by_auth(ServerAuth::NoAuth)
  inspect(noauth_names.length(), content="1")
  inspect(noauth_names[0], content="plain")
}

///|
// End-to-end on the bearer fixture: mcp.json declares a wrong static token,
// so only `set_server_token` can put `good-token` on the wire — connecting
// at all is the precedence proof. reconnect_server must not duplicate tools,
// must bump the catalog revision, and must keep routing intact.
#cfg(target="js")
async test "js set_server_token precedence and reconnect_server" {
  let port_file = "test_fixtures/.http_port_reconnect"
  js_write_text_file(port_file, "")
  let pid = js_start_http_fixture(port_file).wait() catch { _ => -1 }
  if pid < 0 {
    fail("failed to spawn http fixture")
  }
  let mut port = ""
  for _ in 0..<100 {
    port = js_read_text_file(port_file)
    if port != "" {
      break
    }
    @async.sleep(50)
  }
  if port == "" {
    js_kill_pid(pid)
    fail("http fixture did not report a port")
  }
  let http_dir = "test_fixtures/httpdir"
  let mcp_json_path = http_dir + "/.mcp.json"
  js_write_text_file(
    mcp_json_path,
    "{\"mcpServers\":{\"bear\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:" +
    port +
    "/mcp\",\"auth_token\":\"wrong-static-token\"}}}",
  )
  let bridge = match
    MCPToolBridge::discover(
      cwd=http_dir,
      home="test_fixtures/nohome",
      mode=LoadMode::Lazy,
    ) {
    Ok(bridge) => bridge
    Err(message) => {
      js_kill_pid(pid)
      fail("discover failed: " + message)
    }
  }
  bridge.set_server_token("bear", "good-token")
  @async.with_task_group(group => {
    bridge.attach(group)
    inspect(bridge.activate().length(), content="0")
  })
  inspect(@posoco.ToolProvider::list_tools(bridge).length(), content="1")
  inspect(bridge.auth_challenge("bear") is None, content="true")
  let revision_before = bridge.catalog_revision
  match bridge.reconnect_server("bear") {
    Ok(_) => ()
    Err(message) => {
      js_kill_pid(pid)
      fail("reconnect failed: " + message)
    }
  }
  // No duplicate tool, one revision bump, routing still lands the call.
  assert_eq(@posoco.ToolProvider::list_tools(bridge).length(), 1)
  assert_eq(bridge.catalog_revision, revision_before + 1)
  let call : @posoco.ToolCall = {
    call_id: @kernel.CallId::unchecked("call_reconnect"),
    name: @posoco.ToolName::unchecked("bear__ping"),
    arguments: Json::object(Map::from_array([])),
  }
  let outcome = @posoco.ToolProvider::execute(bridge, "bear__ping", call) catch {
    error => {
      js_kill_pid(pid)
      fail("execute failed: " + error.to_string())
    }
  }
  match outcome {
    Success(content~, ..) => inspect(content, content="pong:ok")
    _ => {
      js_kill_pid(pid)
      fail("expected success outcome")
    }
  }
  // An unknown server has no config to reconnect from.
  let ghost = bridge.reconnect_server("ghost")
  inspect(ghost is Err(_), content="true")
  bridge.close()
  js_kill_pid(pid)
}
