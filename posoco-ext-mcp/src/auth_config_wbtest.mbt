///|
// auth_token parsing and ${VAR} expansion tests. Pure JSON/env logic —
// no fs, so these run on native and js alike.

///|
test "auth_token expands env references and literal text" {
  @env.set_env_var("POSOCO_MCP_TEST_TOKEN", "tok-123")
  inspect(
    expand_env_vars("${POSOCO_MCP_TEST_TOKEN}", "srv"),
    content="Ok(tok-123)",
  )
  inspect(
    expand_env_vars("Bearer ${POSOCO_MCP_TEST_TOKEN}!", "srv"),
    content="Ok(Bearer tok-123!)",
  )
  inspect(expand_env_vars("plain-key", "srv"), content="Ok(plain-key)")
  @env.unset_env_var("POSOCO_MCP_TEST_TOKEN")
}

///|
test "auth_token unset variable and malformed reference fail loud" {
  let unset = expand_env_vars("${POSOCO_MCP_MISSING_VAR_9}", "srv")
  inspect(
    match unset {
      Err(message) =>
        message.has_prefix("mcp.json server 'srv'") &&
        message.has_suffix("is not set")
      Ok(_) => false
    },
    content="true",
  )
  let malformed = expand_env_vars("${BAD NAME}", "srv")
  inspect(
    match malformed {
      Err(message) => message.contains("invalid variable name")
      Ok(_) => false
    },
    content="true",
  )
  let unterminated = expand_env_vars("open-${POSOCO_MCP_TEST_TOKEN", "srv")
  inspect(
    match unterminated {
      Err(message) => message.contains("unterminated")
      Ok(_) => false
    },
    content="true",
  )
}

///|
test "http server entry carries auth_token into the transport" {
  let entry : Json = @json.parse(
    "{ \"url\": \"http://127.0.0.1:9/mcp\", \"auth_token\": \"k-1\" }",
  ) catch {
    _ => fail("fixture must parse")
  }
  match parse_server_entry("authed", entry) {
    Ok(config) =>
      match config.transport {
        @transport.AnyTransport::HttpClient(t) =>
          inspect(http_auth_token(t), content="k-1")
        _ => fail("expected http transport")
      }
    Err(message) => fail("parse failed: " + message)
  }
  // No auth_token key → empty token, transport still valid.
  let bare : Json = @json.parse("{ \"url\": \"http://127.0.0.1:9/mcp\" }") catch {
    _ => fail("fixture must parse")
  }
  match parse_server_entry("bare", bare) {
    Ok(config) =>
      match config.transport {
        @transport.AnyTransport::HttpClient(t) =>
          inspect(http_auth_token(t), content="")
        _ => fail("expected http transport")
      }
    Err(message) => fail("parse failed: " + message)
  }
  // Non-string auth_token is a loud config error.
  let wrong : Json = @json.parse(
    "{ \"url\": \"http://127.0.0.1:9/mcp\", \"auth_token\": 42 }",
  ) catch {
    _ => fail("fixture must parse")
  }
  inspect(parse_server_entry("wrong", wrong) is Err(_), content="true")
}
