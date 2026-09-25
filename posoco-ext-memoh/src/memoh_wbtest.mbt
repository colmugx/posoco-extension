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
test "client contract accepts Memoh" {
  require_memoh_client(tk_memoh_impl("memoh"))
}

///|
test "client contract rejects another ACP client" {
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
test "prompt decoder requires exactly one current-turn context" {
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
    decode_memoh_prompt([
      tk_context_block("a"),
      tk_context_block("b"),
    ]),
  ) catch {
    error => Err(error)
  }
  match duplicate {
    Err(InvalidContext(..)) => ()
    _ => fail("expected InvalidContext")
  }
}

///|
async test "context hook injects after stable system prompt and clears at turn end" {
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
  match injected[0] {
    @posoco.Message::SystemMessage(content~) =>
      assert_true(content[0] is @posoco.Content::Text("stable charter"))
    _ => fail("expected stable system message first")
  }
  match injected[1] {
    @posoco.Message::SystemMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(text) => {
          assert_true(text.contains("runtime context"))
          assert_true(text.contains("<memoh-context"))
        }
        _ => fail("expected text host context")
      }
    _ => fail("expected Memoh host context second")
  }
  match injected[2] {
    @posoco.Message::UserMessage(content~) =>
      assert_true(content[0] is @posoco.Content::Text("user request"))
    _ => fail("expected untouched user message")
  }

  memoh.on_turn_end()
  let after = memoh.before_model(messages)
  assert_eq(after.length(), 2)
  match after[1] {
    @posoco.Message::UserMessage(content~) =>
      assert_true(content[0] is @posoco.Content::Text("user request"))
    _ => fail("expected no stale Memoh context after turn end")
  }
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
test "Memoh Tools ACP declaration becomes a host-scoped HTTP MCP config" {
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
          {
            name: "X-Memoh-Session-Id",
            value: "session-1",
            meta: @acp.ProtocolNullable::Omitted,
          },
        ],
      ),
    ]),
  )
  assert_eq(config.name, "Memoh_Tools")
  assert_true(config.auth is @mcp.ServerAuth::NoAuth)
  match config.transport {
    @transport.AnyTransport::HttpClient(http) => {
      assert_eq(http.base_url, "http://127.0.0.1:9999/mcp/runtime-route")
      assert_eq(http.extra_headers.length(), 2)
      assert_eq(http.extra_headers[0].0, "X-Memoh-Runtime-Token")
      assert_eq(http.extra_headers[0].1, "secret-runtime-token")
      assert_eq(http.extra_headers[1].0, "X-Memoh-Session-Id")
      assert_eq(http.extra_headers[1].1, "session-1")
    }
    _ => fail("expected HTTP MCP transport")
  }
}

///|
test "Memoh Tools slug alias is accepted and unrelated MCP servers are ignored" {
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
test "Memoh Tools MCP is required and must use HTTP" {
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
    Err(UnsupportedMcpTransport(transport~)) =>
      assert_eq(transport, "stdio")
    _ => fail("expected UnsupportedMcpTransport")
  }
}

///|
test "Memoh Tools duplicate and empty header names fail without exposing values" {
  let duplicate : Result[@mcp.MCPServerConfig, MemohError] = Ok(
    memoh_tools_mcp_config(
      @acp.ProtocolNullable::Value([
        tk_memoh_http_server("Memoh Tools", []),
        tk_memoh_http_server("Memoh_Tools", []),
      ]),
    ),
  ) catch {
    error => Err(error)
  }
  match duplicate {
    Err(InvalidMcpServer(reason~)) =>
      assert_true(reason.contains("multiple"))
    _ => fail("expected duplicate declaration failure")
  }

  let invalid : Result[@mcp.MCPServerConfig, MemohError] = Ok(
    memoh_tools_mcp_config(
      @acp.ProtocolNullable::Value([
        tk_memoh_http_server(
          "Memoh Tools",
          [
            {
              name: "",
              value: "must-not-appear-in-error",
              meta: @acp.ProtocolNullable::Omitted,
            },
          ],
        ),
      ]),
    ),
  ) catch {
    error => Err(error)
  }
  match invalid {
    Err(InvalidMcpServer(reason~)) => {
      assert_false(reason.contains("must-not-appear-in-error"))
      assert_true(reason.contains("header name"))
    }
    _ => fail("expected invalid header failure")
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
async test "Memoh approval source demotes standing grants to one-shot" {
  let session = TkApprovalSource::{
    decision: @permission.ApprovalDecision::AllowSession,
    asks: 0,
  }
  let wrapped_session = MemohApprovalSource(session)
  assert_true(
    wrapped_session.ask(tk_approval_request()) is
      @permission.ApprovalDecision::AllowOnce,
  )
  assert_eq(session.asks, 1)

  let always = TkApprovalSource::{
    decision: @permission.ApprovalDecision::AllowAlways,
    asks: 0,
  }
  let wrapped_always = MemohApprovalSource(always)
  assert_true(
    wrapped_always.ask(tk_approval_request()) is
      @permission.ApprovalDecision::AllowOnce,
  )
  assert_eq(always.asks, 1)
}

///|
async test "Memoh approval source preserves allow-once and denial" {
  let once = TkApprovalSource::{
    decision: @permission.ApprovalDecision::AllowOnce,
    asks: 0,
  }
  let wrapped_once = MemohApprovalSource(once)
  assert_true(
    wrapped_once.ask(tk_approval_request()) is
      @permission.ApprovalDecision::AllowOnce,
  )

  let denied = TkApprovalSource::{
    decision: @permission.ApprovalDecision::Deny(reason="host denied"),
    asks: 0,
  }
  let wrapped_denied = MemohApprovalSource(denied)
  match wrapped_denied.ask(tk_approval_request()) {
    @permission.ApprovalDecision::Deny(reason~) =>
      assert_eq(reason, "host denied")
    _ => fail("expected denial to be preserved")
  }
}
