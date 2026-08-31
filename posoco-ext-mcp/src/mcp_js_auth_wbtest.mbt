///|
// js-only externs driving the http bearer fixture: spawn (dynamic import of
// node:child_process, like colmugx/mcp's stdio bridge), port-file polling,
// mcp.json generation, cleanup.

///|
#cfg(target="js")
extern "js" fn js_start_http_fixture(
  port_file : String,
) -> @js_async.Promise[Int] =
  #| async (port_file) => {
  #|   const { spawn } = await import('node:child_process')
  #|   return await new Promise((resolve, reject) => {
  #|     const child = spawn(process.execPath, ['test_fixtures/http_bearer_server.mjs', port_file], { stdio: 'ignore' })
  #|     child.once('spawn', () => resolve(child.pid))
  #|     child.once('error', (e) => reject(e))
  #|   })
  #| }

///|
#cfg(target="js")
extern "js" fn js_read_text_file(path : String) -> String =
  #| (p) => {
  #|   try { return require('node:fs').readFileSync(p, 'utf-8') } catch { return '' }
  #| }

///|
#cfg(target="js")
extern "js" fn js_write_text_file(path : String, content : String) -> Unit =
  #| (p, c) => {
  #|   const fs = require('node:fs')
  #|   fs.mkdirSync(p.substring(0, p.lastIndexOf('/')), { recursive: true })
  #|   fs.writeFileSync(p, c)
  #| }

///|
#cfg(target="js")
extern "js" fn js_kill_pid(pid : Int) -> Unit =
  #| (pid) => {
  #|   try { process.kill(pid) } catch {}
  #| }

///|
// End-to-end auth: the fixture http server rejects every request that does
// not carry `Authorization: Bearer good-token`, so a listed tool + successful
// tools/call is proof the token parsed from mcp.json (${VAR} expanded) and
// reached the wire. Wrong token → activation failure; unset env → loud
// discover error (secrets never fall back to anonymous).
#cfg(target="js")
async test "js http bearer auth end-to-end" {
  let port_file = "test_fixtures/.http_port"
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
  // `${` inside a concatenation chain compiles to a JS template literal and
  // would be evaluated by the runtime, so the env reference is assembled.
  let token_ref = "$" + "{POSOCO_MCP_HTTP_TOKEN}"
  // Case 1: token from an env reference — activation, catalog, call.
  @env.set_env_var("POSOCO_MCP_HTTP_TOKEN", "good-token")
  js_write_text_file(
    mcp_json_path,
    "{\"mcpServers\":{\"bear\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:" +
    port +
    "/mcp\",\"auth_token\":\"" +
    token_ref +
    "\"}}}",
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
  @async.with_task_group(group => {
    bridge.attach(group)
    inspect(bridge.activate().length(), content="0")
  })
  inspect(@posoco.ToolProvider::list_tools(bridge).length(), content="1")
  let call : @posoco.ToolCall = {
    call_id: @kernel.CallId::unchecked("call_auth"),
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
  bridge.close()
  // Case 2: a wrong literal token — activation fails, tools stay absent.
  js_write_text_file(
    mcp_json_path,
    "{\"mcpServers\":{\"bear\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:" +
    port +
    "/mcp\",\"auth_token\":\"wrong-token\"}}}",
  )
  let bridge2 = match
    MCPToolBridge::discover(
      cwd=http_dir,
      home="test_fixtures/nohome",
      mode=LoadMode::Lazy,
    ) {
    Ok(bridge) => bridge
    Err(message) => {
      js_kill_pid(pid)
      fail("discover2 failed: " + message)
    }
  }
  @async.with_task_group(group => {
    bridge2.attach(group)
    inspect(bridge2.activate().length(), content="1")
  })
  inspect(@posoco.ToolProvider::list_tools(bridge2).length(), content="0")
  bridge2.close()
  // Case 3: unset env variable — discover itself fails loud. The env
  // reference is restored first (Case 2 overwrote it with a literal).
  js_write_text_file(
    mcp_json_path,
    "{\"mcpServers\":{\"bear\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:" +
    port +
    "/mcp\",\"auth_token\":\"" +
    token_ref +
    "\"}}}",
  )
  @env.unset_env_var("POSOCO_MCP_HTTP_TOKEN")
  let unset = MCPToolBridge::discover(
    cwd=http_dir,
    home="test_fixtures/nohome",
    mode=LoadMode::Lazy,
  )
  inspect(unset is Err(_), content="true")
  js_kill_pid(pid)
}
