///|
/// The provider-owned MCP plane for the GLM Coding Plan's official servers.
///
/// Ownership: this extension dials the three servers itself (the same posture
/// as `posoco-ext-nowledge-mem`, which owns a single lazy MCP client) instead
/// of feeding servers into `posoco-ext-mcp`. The plan's servers are part of
/// *this provider's* entitlement, so their connections, retries and teardown
/// belong to this extension; a host's shared MCP bridge keeps serving the
/// user's own `mcp.json` servers.
///
/// The plane is a narrow seam (`ZaiMcpConnection`) so the lifecycle code never
/// touches the SDK and tests can stay offline.

///|
/// Owner id of the tools companion. Contribution groups are bound to the
/// manifest id, so a renamed extension starts a new group instead of
/// inheriting another one's.
pub fn zai_coding_plan_tools_owner() -> String {
  "posoco_ext_zai_coding_plan_tools"
}

///|
/// Tool-name namespace separator, the MCP convention (`server__tool`). The
/// group id is provider-owned, so splitting on the first separator is
/// unambiguous even when a server-side tool name contains another one.
let zai_mcp_namespace_separator : String = "__"

///|
/// Namespaced tool name for one server-side tool.
pub fn zai_mcp_namespaced_tool(group : String, tool : String) -> String {
  group + zai_mcp_namespace_separator + tool
}

///|
/// One decoded namespaced tool name.
pub(all) struct ZaiMcpRoute {
  group : String
  tool : String
} derive(Eq, Debug)

///|
pub extend ZaiMcpRoute with Eq::{not_equal, equal}

///|
pub extend ZaiMcpRoute with Debug::{to_repr}

///|
/// Split a namespaced tool name back into (group, server-side tool). A name
/// without a separator, or with an empty side, is not one of ours.
pub fn zai_mcp_route(tool : String) -> ZaiMcpRoute? {
  let separator = zai_mcp_namespace_separator
  match tool.find(separator) {
    None => None
    Some(index) =>
      if index <= 0 || index + separator.length() >= tool.length() {
        None
      } else {
        Some({
          group: tool.exact_view(end=index).to_owned(),
          tool: tool.exact_view(start=index + separator.length()).to_owned(),
        })
      }
  }
}

///|
/// One attempt's outcome: the tools that answered plus the failures that did
/// not. A partial plane is a first-class result — publishing two of three
/// servers is better than publishing none, as long as the missing one stays
/// visible.
pub(all) struct ZaiMcpOpen {
  tools : Array[@posoco.ToolDef]
  connected : Int32
  failures : Array[String]
} derive(Debug)

///|
pub extend ZaiMcpOpen with Debug::{to_repr}

///|
/// Narrow seam: one live connection set for one published version.
///
/// Implementations are cheap to create and own their clients; retirement
/// closes exactly one instance, never a shared one.
pub(open) trait ZaiMcpConnection {
  /// Tool definitions captured at connect time (names already namespaced).
  fn tools(Self) -> Array[@posoco.ToolDef]
  /// Number of declared groups that answered `tools/list`.
  fn connected_groups(Self) -> Int32
  /// Sanitized failure lines for groups that did not answer.
  fn failures(Self) -> Array[String]
  /// Call one namespaced tool; `Ok(output)` is the model-visible text.
  async fn call(Self, tool : String, arguments : Json) -> Result[String, String] noraise
  /// Close every client. Retry-safe: closing twice is a no-op.
  async fn close(Self) -> Unit noraise
}

///|
/// Join the text content items of one MCP call. Non-text items degrade to an
/// explicit marker rather than disappearing, so the model can tell that
/// something was returned.
fn zai_mcp_content_text(items : Array[@types.ContentBlock]) -> String {
  items
  .map(fn(item) {
    match item {
      @types.ContentBlock::Text(text, ..) => text
      @types.ContentBlock::Image(_, mime_type~, ..) => "[image \{mime_type}]"
      @types.ContentBlock::Audio(_, mime_type~, ..) => "[audio \{mime_type}]"
      @types.ContentBlock::ResourceLink(data, ..) => "[resource \{data.uri}]"
      @types.ContentBlock::EmbeddedResource(contents, ..) =>
        "[resource \{contents.uri}]"
      @types.ContentBlock::Unknown(_) => "[unknown content]"
    }
  })
  .join("\n")
}

///|
/// Close one client, swallowing the SDK's error: teardown has no recovery and
/// a failed close must not fail the retire callback (which is retried).
async fn zai_mcp_close_client(client : @client.MCPClient) -> Unit noraise {
  let _ = client.close() catch { _ => () }
}

///|
/// Production plane: one streamable-HTTP client per declared group, dialed
/// with the plan key at open time.
///
/// The era probe stays `Auto`: unlike the Nowledge Mem server (which rejects
/// the modern probe), nothing here documents a legacy-only handshake.
pub(all) struct HttpZaiMcp {
  api_key : String
  client_name : String
  client_version : String
  mut clients : Map[String, @client.MCPClient]
  mut defs : Array[@posoco.ToolDef]
  mut connected : Int32
  mut failures : Array[String]
  mut closed : Bool
}

///|
pub fn HttpZaiMcp::HttpZaiMcp(
  api_key~ : String,
  client_name~ : String = "zai-coding-plan",
  client_version~ : String = "0.1.0",
) -> HttpZaiMcp {
  {
    api_key,
    client_name,
    client_version,
    clients: Map::from_array([]),
    defs: [],
    connected: 0,
    failures: [],
    closed: false,
  }
}

///|
/// Sanitize one connect/list failure for the status surface: the label and the
/// SDK's message only, never a URL with a credential or a body.
fn zai_mcp_failure(group : String, reason : String) -> String {
  @devkit.sanitize_label(group) + ": " + reason
}

///|
/// Connect every declared group and capture its tools. Groups connect
/// sequentially: three servers is small enough that determinism (and an
/// ordered failure list) beats parallel start-up, and a slow server must not
/// delay the others' failures from being reported.
async fn HttpZaiMcp::open(
  self : HttpZaiMcp,
  groups : Array[ZaiToolGroup],
) -> Unit noraise {
  for group in groups {
    if self.closed {
      return
    }
    let connected = try
      @client.MCPClient::connect_http(
        url=group.endpoint,
        name=self.client_name,
        version=self.client_version,
        auth_token=self.api_key,
      )
    catch {
      @types.MCPError::_ as err =>
        // A failed handshake leaves nothing to close: the SDK tears its own
        // transport down before raising.
        Err(zai_mcp_failure(group.group, err.message()))
      _ => Err(zai_mcp_failure(group.group, "connect failed"))
    } noraise {
      client => Ok(client)
    }
    let client = match connected {
      Ok(client) => client
      Err(reason) => {
        self.failures.push(reason)
        continue
      }
    }
    let listed = try client.list_tools() catch {
      @types.MCPError::_ as err =>
        Err(zai_mcp_failure(group.group, err.message()))
      _ => Err(zai_mcp_failure(group.group, "tools/list failed"))
    } noraise {
      listed => Ok(listed)
    }
    match listed {
      Err(reason) => {
        zai_mcp_close_client(client)
        self.failures.push(reason)
      }
      Ok(listed) => {
        self.clients[group.group] = client
        self.connected = self.connected + 1
        for tool in listed.tools {
          self.defs.push(
            @posoco.ToolDef(
              name=@posoco.ToolName::unchecked(
                zai_mcp_namespaced_tool(group.group, tool.name),
              ),
              description=tool.description.unwrap_or(""),
              input_schema=tool.input_schema,
              owner=@posoco.OwnerId::unchecked(zai_coding_plan_tools_owner()),
              policy=@posoco.ExecutionPolicy::Parallel,
              provenance=Some(zai_coding_plan_tools_owner() + ":" + group.group),
            ),
          )
        }
      }
    }
  }
}

///|
pub impl ZaiMcpConnection for HttpZaiMcp with fn tools(self : HttpZaiMcp) -> Array[
  @posoco.ToolDef,
] {
  self.defs.copy()
}

///|
pub impl ZaiMcpConnection for HttpZaiMcp with fn connected_groups(
  self : HttpZaiMcp,
) -> Int32 {
  self.connected
}

///|
pub impl ZaiMcpConnection for HttpZaiMcp with fn failures(self : HttpZaiMcp) -> Array[
  String,
] {
  self.failures.copy()
}

///|
pub impl ZaiMcpConnection for HttpZaiMcp with fn call(
  self : HttpZaiMcp,
  tool : String,
  arguments : Json,
) -> Result[String, String] noraise {
  let route = match zai_mcp_route(tool) {
    Some(route) => route
    None => return Err("unknown tool name: " + @devkit.sanitize_label(tool))
  }
  let client = match self.clients.get(route.group) {
    Some(client) => client
    None =>
      return Err(
        "server '" + @devkit.sanitize_label(route.group) + "' is not connected",
      )
  }
  let result = try
    client.call_tool(route.tool, arguments=arguments.stringify())
  catch {
    @types.MCPError::_ as err =>
      Err(@devkit.sanitize_label(route.group) + ": " + err.message())
    _ => Err(@devkit.sanitize_label(route.group) + ": call failed")
  } noraise {
    result => Ok(result)
  }
  match result {
    Err(reason) => Err(reason)
    Ok(result) => {
      let text = zai_mcp_content_text(result.content)
      if result.is_error.unwrap_or(false) {
        Err(text)
      } else {
        Ok(text)
      }
    }
  }
}

///|
pub impl ZaiMcpConnection for HttpZaiMcp with fn close(self : HttpZaiMcp) -> Unit noraise {
  self.closed = true
  for _, client in self.clients {
    zai_mcp_close_client(client)
  }
  self.clients.clear()
  self.defs.clear()
}

///|
pub extend HttpZaiMcp with ZaiMcpConnection::{
  call,
  close,
  connected_groups,
  failures,
  tools,
}

///|
/// The published face: a `ToolProvider` over one connection set. Core captures
/// this provider per operation, so the definitions and the executor stay
/// paired for the version that published them.
pub(all) struct ZaiMcpToolProvider {
  connection : &ZaiMcpConnection
}

///|
pub fn ZaiMcpToolProvider::ZaiMcpToolProvider(
  connection~ : &ZaiMcpConnection,
) -> ZaiMcpToolProvider {
  { connection, }
}

///|
pub impl @posoco.ToolProvider for ZaiMcpToolProvider with fn list_tools(
  self : ZaiMcpToolProvider,
) -> Array[@posoco.ToolDef] {
  self.connection.tools()
}

///|
pub impl @posoco.ToolProvider for ZaiMcpToolProvider with fn execute(
  self : ZaiMcpToolProvider,
  ctx : @posoco.ToolCallContext,
) -> @kernel.ToolOutcome raise @posoco.RuntimeError {
  // The plane reports a server-side failure as a business answer (the model
  // can retry or explain), never as a runtime defect of the agent.
  match self.connection.call(ctx.name.to_string(), ctx.arguments) {
    Ok(text) => @kernel.ToolOutcome::Success(content=text, structured=None)
    Err(text) =>
      @kernel.ToolOutcome::ToolReportedError(content=text, structured=None)
  }
}

///|
pub extend ZaiMcpToolProvider with @posoco.ToolProvider::{execute, list_tools}

///|
/// One `open` call: build a fresh connection set, dial it, and report what
/// answered. The caller owns the instance and retires it through `close`.
pub async fn zai_mcp_open(
  api_key~ : String,
  groups~ : Array[ZaiToolGroup],
) -> Result[&ZaiMcpConnection, String] noraise {
  let plane = HttpZaiMcp::HttpZaiMcp(api_key~)
  plane.open(groups)
  if plane.connected == 0 {
    // Nothing answered: hand back the reason instead of an empty group, so
    // the caller reports a failure instead of "0/3 announced".
    let reason = if plane.failures.is_empty() {
      "no MCP server declared"
    } else {
      plane.failures.join("; ")
    }
    plane.close()
    return Err(reason)
  }
  Ok(plane as &ZaiMcpConnection)
}

///|
/// Unlabelled default opener, so the companion can hold it as a function value.
pub async fn zai_mcp_open_default(
  api_key : String,
  groups : Array[ZaiToolGroup],
) -> Result[&ZaiMcpConnection, String] noraise {
  zai_mcp_open(api_key~, groups~)
}
