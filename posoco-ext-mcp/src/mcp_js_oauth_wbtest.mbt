///|
// js-only end-to-end: the equivalent of the future host `/mcp login`
// orchestration, driven against test_fixtures/http_oauth_server.mjs (one
// process playing resource server + authorization server):
//   activation 401 challenge -> auth_challenge capture
//   -> RFC 9728 resource metadata -> RFC 8414 server metadata
//   -> RFC 7591 dynamic registration -> RFC 8628 device flow (auto-approved)
//   -> set_server_token + reconnect -> tools/call
//   -> refresh grant -> re-inject -> reconnect -> tools/call again
// The file/kill externs come from mcp_js_auth_wbtest.mbt; spawning needs its
// own extern because js_start_http_fixture hardcodes the bearer script.

///|
#cfg(target="js")
extern "js" fn js_start_oauth_fixture(
  port_file : String,
) -> @js_async.Promise[Int] =
  #| async (port_file) => {
  #|   const { spawn } = await import('node:child_process')
  #|   return await new Promise((resolve, reject) => {
  #|     const child = spawn(process.execPath, ['test_fixtures/http_oauth_server.mjs', port_file], { stdio: 'ignore' })
  #|     child.once('spawn', () => resolve(child.pid))
  #|     child.once('error', (e) => reject(e))
  #|   })
  #| }

///|
#cfg(target="js")
async test "js oauth login chain end-to-end" {
  let port_file = "test_fixtures/.http_port_oauth"
  js_write_text_file(port_file, "")
  let pid = js_start_oauth_fixture(port_file).wait() catch { _ => -1 }
  if pid < 0 {
    fail("failed to spawn oauth fixture")
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
    fail("oauth fixture did not report a port")
  }
  // Step 1: the server entry is auth:"oauth" with no static token — nothing
  // on the wire until the host logs in.
  let oauth_dir = "test_fixtures/oauthdir"
  js_write_text_file(
    oauth_dir + "/.mcp.json",
    "{\"mcpServers\":{\"oa\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:" +
    port +
    "/mcp\",\"auth\":\"oauth\"}}}",
  )
  let bridge = match
    MCPToolBridge::discover(
      cwd=oauth_dir,
      home="test_fixtures/nohome",
      mode=LoadMode::Lazy,
    ) {
    Ok(bridge) => bridge
    Err(message) => {
      js_kill_pid(pid)
      fail("discover failed: " + message)
    }
  }
  // Step 2: activation eats the 401 — one recorded failure, no tools, and the
  // protected-resource URI captured for the login flow.
  @async.with_task_group(group => {
    bridge.attach(group)
    inspect(bridge.activate().length(), content="1")
  })
  let revision_after_activate = bridge.catalog_revision
  inspect(@posoco.ToolProvider::list_tools(bridge).length(), content="0")
  let challenge = match bridge.auth_challenge("oa") {
    Some(uri) => uri
    None => {
      js_kill_pid(pid)
      fail("expected a captured 401 resource-metadata challenge")
    }
  }
  // Step 3: the default transport drives every OAuth HTTP hop.
  let default_transport = @oauth.DefaultOAuthHttpTransport::DefaultOAuthHttpTransport()
  let transport : &@oauth.OAuthHttpTransport = default_transport
  // Step 4: RFC 9728 protected-resource metadata.
  let resource_md = @oauth.fetch_resource_metadata(challenge, transport) catch {
    _ => {
      js_kill_pid(pid)
      fail("fetch_resource_metadata failed")
    }
  }
  if resource_md.authorization_servers.length() == 0 {
    js_kill_pid(pid)
    fail("resource metadata listed no authorization servers")
  }
  let as_url = resource_md.authorization_servers[0]
  // Step 5: RFC 8414 authorization-server metadata.
  let server_md = @oauth.fetch_server_metadata(
    as_url + "/.well-known/oauth-authorization-server",
    transport,
  ) catch {
    _ => {
      js_kill_pid(pid)
      fail("fetch_server_metadata failed")
    }
  }
  let registration_endpoint = match server_md.registration_endpoint {
    Some(endpoint) => endpoint
    None => {
      js_kill_pid(pid)
      fail("server metadata has no registration_endpoint")
    }
  }
  let device_endpoint = match server_md.device_authorization_endpoint {
    Some(endpoint) => endpoint
    None => {
      js_kill_pid(pid)
      fail("server metadata has no device_authorization_endpoint")
    }
  }
  // Step 6: RFC 7591 dynamic registration.
  let client_id = @oauth.register_client(
    registration_endpoint, "posoco-e2e", transport,
  ) catch {
    _ => {
      js_kill_pid(pid)
      fail("register_client failed")
    }
  }
  inspect(client_id.has_prefix("client-"), content="true")
  // Step 7: RFC 8628 device flow — the fixture auto-approves on the first
  // token poll, so the second poll issues the tokens.
  let flow_config = @oauth.DeviceFlowConfig::DeviceFlowConfig(
    client_id~,
    device_auth_endpoint=device_endpoint,
    token_endpoint=server_md.token_endpoint,
  )
  let noop = @oauth.NoopAuthInteraction::NoopAuthInteraction()
  let interaction : &@oauth.AuthInteraction = noop
  let credential = @oauth.run_device_flow_with_transport(
    flow_config, interaction, transport,
  ) catch {
    _ => {
      js_kill_pid(pid)
      fail("device flow failed")
    }
  }
  inspect(credential.access_token.has_prefix("at-"), content="true")
  inspect(credential.refresh_token.has_prefix("rt-"), content="true")
  // Step 8: inject the access token, reconnect, and call the tool.
  bridge.set_server_token("oa", credential.access_token)
  match bridge.reconnect_server("oa") {
    Ok(_) => ()
    Err(message) => {
      js_kill_pid(pid)
      fail("reconnect with device-flow token failed: " + message)
    }
  }
  inspect(@posoco.ToolProvider::list_tools(bridge).length(), content="1")
  assert_eq(bridge.catalog_revision, revision_after_activate + 1)
  let call : @posoco.ToolCall = {
    call_id: @kernel.CallId::unchecked("call_oauth_login"),
    name: @posoco.ToolName::unchecked("oa__oauth_tool"),
    arguments: Json::object(Map::from_array([])),
  }
  let outcome = @posoco.ToolProvider::execute(bridge, "oa__oauth_tool", call) catch {
    error => {
      js_kill_pid(pid)
      fail("execute with device-flow token failed: " + error.to_string())
    }
  }
  match outcome {
    Success(content~, ..) => inspect(content, content="oauth:ok")
    _ => {
      js_kill_pid(pid)
      fail("expected success outcome from oauth_tool")
    }
  }
  // Step 9: the refresh grant rotates the access token, and the fixture
  // revokes the token issued with the device flow — so a successful call
  // after this reconnect proves the refreshed token reached the wire.
  let refreshed = @oauth.run_refresh_flow(
    token_endpoint=server_md.token_endpoint,
    client_id~,
    refresh_token=credential.refresh_token,
    transport~,
  ) catch {
    _ => {
      js_kill_pid(pid)
      fail("refresh flow failed")
    }
  }
  inspect(refreshed.access_token != credential.access_token, content="true")
  bridge.set_server_token("oa", refreshed.access_token)
  match bridge.reconnect_server("oa") {
    Ok(_) => ()
    Err(message) => {
      js_kill_pid(pid)
      fail("reconnect with refreshed token failed: " + message)
    }
  }
  assert_eq(bridge.catalog_revision, revision_after_activate + 2)
  assert_eq(@posoco.ToolProvider::list_tools(bridge).length(), 1)
  let call2 : @posoco.ToolCall = {
    call_id: @kernel.CallId::unchecked("call_oauth_refresh"),
    name: @posoco.ToolName::unchecked("oa__oauth_tool"),
    arguments: Json::object(Map::from_array([])),
  }
  let outcome2 = @posoco.ToolProvider::execute(bridge, "oa__oauth_tool", call2) catch {
    error => {
      js_kill_pid(pid)
      fail("execute with refreshed token failed: " + error.to_string())
    }
  }
  match outcome2 {
    Success(content~, ..) => inspect(content, content="oauth:ok")
    _ => {
      js_kill_pid(pid)
      fail("expected success outcome after refresh")
    }
  }
  // Step 10: nothing left running.
  bridge.close()
  js_kill_pid(pid)
}
