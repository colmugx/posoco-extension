///|
async test "memoh session store is intentionally ephemeral" {
  let memoh = Memoh()
  let first = memoh.load("s1")
  assert_eq(first.messages.length(), 0)
  assert_eq(first.metadata.length(), 0)

  let user = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("hello"),
  ])
  let dirty = @posoco.Session::{
    messages: [user],
    metadata: Map::from_array([("marker", Json::string("value"))]),
  }
  memoh.save("s1", dirty)
  memoh.append_messages("s1", 0, [user][:])
  memoh.truncate("s1", 0)

  let after = memoh.load("s1")
  assert_eq(after.messages.length(), 0)
  assert_eq(after.metadata.length(), 0)
}

///|
test "memoh extension contributes session store and context hook" {
  let memoh = Memoh()
  assert_eq(memoh.extension_id(), "posoco_ext_memoh")
  let manifest = memoh.manifest()
  assert_eq(manifest.sessions.length(), 1)
  assert_eq(manifest.hooks.length(), 1)
  assert_eq(manifest.tools.length(), 0)
}

///|
fn tk_memoh_impl(name : String) -> @acp.ProtocolNullable[@acp.Implementation] {
  @acp.ProtocolNullable::Value({
    name,
    title: @acp.ProtocolNullable::Omitted,
    version: "test",
    meta: @acp.ProtocolNullable::Omitted,
  })
}

///|
test "client contract accepts only Memoh" {
  require_memoh_client(tk_memoh_impl("memoh"))
  let result : Result[Unit, MemohError] = Ok(
    require_memoh_client(tk_memoh_impl("zed")),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(InvalidClient(..)) => ()
    _ => fail("expected InvalidClient")
  }
}

///|
fn tk_context_block(text : String) -> @acp.ContentBlock {
  @acp.ContentBlock::Resource({
    annotations: @acp.ProtocolNullable::Omitted,
    resource: @acp.EmbeddedResourceResource::Text({
      mime_type: @acp.ProtocolNullable::Value("text/markdown"),
      text,
      uri: MEMOH_CURRENT_TURN_URI,
      meta: @acp.ProtocolNullable::Omitted,
    }),
    meta: @acp.ProtocolNullable::Omitted,
  })
}

///|
test "prompt decoder separates host context from user text and image" {
  let prompt = decode_memoh_prompt([
    tk_context_block("runtime context"),
    @acp.ContentBlock::Text({
      annotations: @acp.ProtocolNullable::Omitted,
      text: "fix it",
      meta: @acp.ProtocolNullable::Omitted,
    }),
    @acp.ContentBlock::Image({
      annotations: @acp.ProtocolNullable::Omitted,
      data: "aGVsbG8=",
      mime_type: "image/png",
      uri: @acp.ProtocolNullable::Omitted,
      meta: @acp.ProtocolNullable::Omitted,
    }),
  ])
  assert_eq(prompt.context.text, "runtime context")
  assert_eq(prompt.user_content.length(), 2)
  assert_true(prompt.user_content[0] is @posoco.Content::Text("fix it"))
  assert_true(
    prompt.user_content[1] is @posoco.Content::Image(
      media_type="image/png",
      data="aGVsbG8=",
    ),
  )
}

///|
test "prompt decoder requires one current-turn context" {
  let missing : Result[MemohPrompt, MemohError] = Ok(
    decode_memoh_prompt([
      @acp.ContentBlock::Text({
        annotations: @acp.ProtocolNullable::Omitted,
        text: "hello",
        meta: @acp.ProtocolNullable::Omitted,
      }),
    ]),
  ) catch {
    error => Err(error)
  }
  match missing {
    Err(MissingContext) => ()
    _ => fail("expected MissingContext")
  }

  let duplicate : Result[MemohPrompt, MemohError] = Ok(
    decode_memoh_prompt([tk_context_block("a"), tk_context_block("b")]),
  ) catch {
    error => Err(error)
  }
  match duplicate {
    Err(InvalidContext(..)) => ()
    _ => fail("expected InvalidContext")
  }
}

///|
async test "context hook injects host context and clears it at turn end" {
  let memoh = Memoh()
  let prompt = decode_memoh_prompt([
    tk_context_block("runtime context"),
    @acp.ContentBlock::Text({
      annotations: @acp.ProtocolNullable::Omitted,
      text: "user request",
      meta: @acp.ProtocolNullable::Omitted,
    }),
  ])
  let user = memoh.prepare_turn(prompt)
  let stable : @posoco.Message = @posoco.Message::SystemMessage(content=[
    @posoco.Content::Text("stable charter"),
  ])
  let messages = [stable, user]
  let injected = memoh.before_model(messages)
  assert_eq(injected.length(), 3)
  match injected[1] {
    @posoco.Message::SystemMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(text) => {
          assert_true(text.contains("runtime context"))
          assert_true(text.contains("<memoh-context"))
        }
        _ => fail("expected text host context")
      }
    _ => fail("expected host context system message")
  }

  memoh.on_turn_end()
  assert_eq(memoh.before_model(messages).length(), 2)
}

///|
fn tk_memoh_http_server(
  name : String,
  headers : Array[@acp.McpHttpHeader],
) -> @acp.McpServer {
  @acp.McpServer::Http({
    name,
    url: "http://127.0.0.1:9999/mcp/runtime-route",
    headers,
    meta: @acp.ProtocolNullable::Omitted,
  })
}

///|
test "Memoh Tools maps to host-scoped HTTP MCP config" {
  let config = memoh_tools_mcp_config(
    @acp.ProtocolNullable::Value([
      tk_memoh_http_server(
        "Memoh Tools",
        [
          {
            name: "X-Memoh-Runtime-Token",
            value: "secret-runtime-token",
            meta: @acp.ProtocolNullable::Omitted,
          },
        ],
      ),
    ]),
  )
  assert_eq(config.name, MEMOH_TOOLS_MCP_SLUG)
  assert_true(config.auth is @mcp.ServerAuth::NoAuth)
  match config.transport {
    @transport.AnyTransport::HttpClient(http) => {
      assert_eq(http.extra_headers.length(), 1)
      assert_eq(http.extra_headers[0].0, "X-Memoh-Runtime-Token")
      assert_eq(http.extra_headers[0].1, "secret-runtime-token")
    }
    _ => fail("expected HTTP MCP transport")
  }
}

///|
test "Memoh Tools slug alias works and unrelated MCP servers are ignored" {
  let unrelated : @acp.McpServer = @acp.McpServer::Http({
    name: "Other Server",
    url: "https://example.test/mcp",
    headers: [],
    meta: @acp.ProtocolNullable::Omitted,
  })
  let config = memoh_tools_mcp_config(
    @acp.ProtocolNullable::Value([
      unrelated,
      tk_memoh_http_server("memoh_tools", []),
    ]),
  )
  assert_eq(config.name, MEMOH_TOOLS_MCP_SLUG)
}

///|
test "Memoh Tools is required and must use HTTP" {
  let missing : Result[@mcp.MCPServerConfig, MemohError] = Ok(
    memoh_tools_mcp_config(@acp.ProtocolNullable::Omitted),
  ) catch {
    error => Err(error)
  }
  match missing {
    Err(MissingToolGateway) => ()
    _ => fail("expected MissingToolGateway")
  }

  let stdio : @acp.McpServer = @acp.McpServer::Stdio({
    name: "Memoh Tools",
    command: "/bin/false",
    args: [],
    env: [],
    meta: @acp.ProtocolNullable::Omitted,
  })
  let unsupported : Result[@mcp.MCPServerConfig, MemohError] = Ok(
    memoh_tools_mcp_config(@acp.ProtocolNullable::Value([stdio])),
  ) catch {
    error => Err(error)
  }
  match unsupported {
    Err(UnsupportedMcpTransport(transport~)) => assert_eq(transport, "stdio")
    _ => fail("expected UnsupportedMcpTransport")
  }
}

///|
struct TkApprovalSource {
  decision : @permission.ApprovalDecision
  mut asks : Int
}

///|
pub impl @permission.ApprovalSource for TkApprovalSource with fn ask(
  self : TkApprovalSource,
  _request : @permission.ApprovalRequest,
) -> @permission.ApprovalDecision {
  self.asks += 1
  self.decision
}

///|
pub extend TkApprovalSource with @permission.ApprovalSource::{ask}

///|
fn tk_approval_request() -> @permission.ApprovalRequest {
  {
    tool_name: "edit",
    call_id: "call-1",
    category: "write",
    arguments_preview: "{}",
    arguments: Json::object({}),
  }
}

///|
async test "Memoh approval source never creates local standing grants" {
  let delegate = TkApprovalSource::{
    decision: @permission.ApprovalDecision::AllowAlways,
    asks: 0,
  }
  let wrapped = MemohApprovalSource(delegate)
  assert_true(
    wrapped.ask(tk_approval_request()) is
      @permission.ApprovalDecision::AllowOnce,
  )
  assert_eq(delegate.asks, 1)
}

///|
async fn tk_support_new(
  _context : @acp.AgentContext,
  _params : @acp.NewSessionParams,
) -> @acp.NewSessionResult {
  @async.sleep(0)
  {
    session_id: "s1",
    modes: @acp.ProtocolNullable::Omitted,
    config_options: @acp.ProtocolNullable::Omitted,
    meta: @acp.ProtocolNullable::Omitted,
  }
}

///|
async fn tk_support_prompt(
  _context : @acp.AgentContext,
  _params : @acp.PromptParams,
) -> @acp.PromptResult {
  @async.sleep(0)
  {
    stop_reason: @acp.StopReason::EndTurn,
    meta: @acp.ProtocolNullable::Omitted,
  }
}

///|
async fn tk_support_cancel(
  _context : @acp.AgentContext,
  _params : @acp.CancelParams,
) -> Unit {
  @async.sleep(0)
}

///|
test "Memoh agent support advertises image embedded context and HTTP MCP" {
  let spec = @acp.agent_spec(
    info={
      name: "test-memoh-agent",
      title: @acp.ProtocolNullable::Omitted,
      version: "0",
      meta: @acp.ProtocolNullable::Omitted,
    },
    sessions=@acp.agent_session_service(
      new_session=tk_support_new,
      prompt=tk_support_prompt,
      cancel=tk_support_cancel,
    ),
    support=memoh_agent_support(),
  ).unwrap()
  let caps = @acp.agent_endpoint_from_spec(spec).capabilities()
  match caps.prompt_capabilities {
    @acp.ProtocolNullable::Value(prompt) => {
      match prompt.image {
        @acp.ProtocolNullable::Value(true) => ()
        _ => fail("expected image support")
      }
      match prompt.embedded_context {
        @acp.ProtocolNullable::Value(true) => ()
        _ => fail("expected embedded context support")
      }
    }
    _ => fail("expected prompt capabilities")
  }
  match caps.mcp_capabilities {
    @acp.ProtocolNullable::Value(mcp) =>
      match mcp.http {
        @acp.ProtocolNullable::Value(true) => ()
        _ => fail("expected HTTP MCP support")
      }
    _ => fail("expected MCP capabilities")
  }
}
