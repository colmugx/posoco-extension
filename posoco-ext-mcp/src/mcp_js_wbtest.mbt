///|
// js end-to-end: discover (js file read) → attach → activate (js stdio
// spawn + handshake + list_tools) → catalog → execute (tools/call round
// trip), against the local fixture server in test_fixtures/.
//
// Paths are relative to the module root — `moon test` runs there — and
// home points at a nonexistent directory so only the project-level
// test_fixtures/.mcp.json contributes.

///|
#cfg(target="js")
async test "js end-to-end discover activate list execute" {
  let bridge = match
    MCPToolBridge::discover(
      cwd="test_fixtures",
      home="test_fixtures/nohome",
      mode=LoadMode::Lazy,
    ) {
    Ok(bridge) => bridge
    Err(message) => fail("discover failed: " + message)
  }
  // Lazy posture: nothing connected before activation.
  inspect(@posoco.ToolProvider::list_tools(bridge).length(), content="0")
  @async.with_task_group(group => {
    bridge.attach(group)
    let failures = bridge.activate()
    inspect(failures.length(), content="0")
  })
  let names : Array[String] = []
  for tool in @posoco.ToolProvider::list_tools(bridge) {
    names.push(tool.name.to_string())
  }
  // `dirty` carries an off-Kernel-subset schema; the bridge sanitizes it, so
  // it must still be advertised alongside the clean one.
  debug_inspect(names, content="[\"echo__echo\", \"echo__dirty\"]")
  let call : @posoco.ToolCall = {
    call_id: @kernel.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("echo__echo"),
    arguments: Json::object(Map::from_array([("k", Json::string("v"))])),
  }
  let outcome = @posoco.ToolProvider::execute(bridge, "echo__echo", call) catch {
    error => fail("execute failed: " + error.to_string())
  }
  match outcome {
    Success(content~, ..) => inspect(content, content="echo:{\"k\":\"v\"}")
    _ => fail("expected success outcome")
  }
  // Live `/mcp` status after activation: connected rows carry real tool
  // counts, which is exactly the visibility a down server was missing.
  let status = @posoco.CommandPort::invoke(bridge, "mcp", Json::null()) catch {
    error => fail("mcp invoke failed: " + error.to_string())
  }
  match status {
    Success(feedback~, structured=Some(structured), ..) => {
      inspect(
        feedback,
        content=(
          #|1 server: 1 connected, 0 failed, 0 pending
          #|- echo: connected, 2 tools
        ),
      )
      inspect(
        structured.stringify(),
        content="{\"kind\":\"mcp_status\",\"mode\":\"lazy\",\"servers\":[{\"name\":\"echo\",\"status\":\"connected\",\"tools\":2}]}",
      )
    }
    _ => fail("expected mcp status success")
  }
  let refreshed = @posoco.CommandPort::invoke(
    bridge,
    "mcp",
    Json::object(Map::from_array([("action", Json::string("refresh"))])),
  ) catch {
    error => fail("mcp refresh invoke failed: " + error.to_string())
  }
  match refreshed {
    Success(feedback~, ..) =>
      inspect(
        feedback,
        content=(
          #|1 server: 1 connected, 0 failed, 0 pending
          #|- echo: connected, 2 tools
          #|(refreshed tool lists from connected servers)
        ),
      )
    _ => fail("expected mcp refresh success")
  }
  bridge.close()
}
