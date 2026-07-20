///|
/// posoco_ext_mcp.mbt — Posoco MCP Extension
///
/// Bridges colmugx/mcp client with posoco's unified ToolProvider trait.
/// Enables posoco agents to discover and call tools from MCP servers.

///|
/// ——— Namespace helpers ———

///|
/// Extract (cmd, args) from a StdioClientTransport for connect_stdio dispatch.
fn stdio_cmd(t : @transport.StdioClientTransport) -> (String, Array[String]) {
  (t.cmd, t.args)
}

///|
/// Extract base_url from an HttpClientTransport for connect_http dispatch.
fn http_url(t : @transport.HttpClientTransport) -> String {
  t.base_url
}

///|
/// Double-underscore separator between server name and tool name.
fn namespaced_tool_name(server_name : String, tool_name : String) -> String {
  "\{server_name}__\{tool_name}"
}

///|
/// Keep server and tool identifiers useful but bounded in diagnostics. MCP
/// transport errors and response bodies are intentionally not serialized.
fn diagnostic_label(value : String) -> String {
  let builder = StringBuilder::new()
  let mut count = 0
  for ch in value {
    if count >= 120 {
      builder.write_string("...")
      break
    }
    match ch {
      '\n' | '\r' | '\t' => builder.write_char(' ')
      _ => builder.write_char(ch)
    }
    count += 1
  }
  builder.to_string()
}

///|
fn strip_namespace(namespaced : String, server_name : String) -> String {
  let prefix = "\{server_name}__"
  if namespaced.has_prefix(prefix) {
    namespaced[prefix.length():].to_owned()
  } else {
    namespaced
  }
}

///|
/// ——— Type conversion helpers ———

///|
/// Convert MCP ToolDefinition to Posoco ToolDef with namespace prefix.
fn convert_tool_def(
  mcp_tool : @types.ToolDefinition,
  server_name : String,
) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: namespaced_tool_name(server_name, mcp_tool.name),
    description: mcp_tool.description,
    input_schema: mcp_tool.input_schema,
    metadata: None,
    source: Some("posoco_ext_mcp:\{server_name}"),
  }
}

///|
/// Convert MCP ContentItem array to a plain text string.
fn convert_content_to_string(items : Array[@types.ContentItem]) -> String {
  let parts : Array[String] = []
  for item in items {
    match item {
      @types.ContentItem::Text(t) => parts.push(t)
      @types.ContentItem::Image(data, mime_type~) =>
        parts.push("[Image: \{mime_type}, \{data.length()} chars]")
      @types.ContentItem::ResourceLink(uri) => parts.push("[Resource: \{uri}]")
      @types.ContentItem::EmbeddedResource(content) =>
        match content {
          @types.EmbeddedResourceContent::Text(t, uri~, ..) =>
            parts.push("[Resource \{uri}]: \{t}")
          @types.EmbeddedResourceContent::Blob(b, uri~, ..) =>
            parts.push("[Resource \{uri}]: [blob \{b.length()} chars]")
        }
    }
  }
  parts.join("\n")
}

///|
/// ——— Configuration & Connection Types ———

///|
/// Configuration for a single MCP server connection.
pub(all) struct MCPServerConfig {
  name : String
  transport : @transport.AnyTransport
}

///|
/// Internal: a connected MCP server with cached tool list.
struct MCPServerConn {
  name : String
  client : @client.MCPClient
  mut cached_tools : Array[@posoco.ToolDef]
  _server_info : @types.ServerInfo?
}

///|
/// A complete candidate catalog for one connection. Refresh builds all of
/// these before it is allowed to mutate bridge state.
priv struct CatalogEntry {
  connection_index : Int
  tools : Array[@posoco.ToolDef]
}

///|
/// Validated catalog replacement. Entry order is required to match connection
/// order, so committing the plan cannot discover a late validation failure.
priv struct CatalogPlan {
  entries : Array[CatalogEntry]
  tool_to_conn : Map[String, Int]
}

///|
/// Convert an initialization result while guaranteeing that a resource
/// acquired earlier in the sequence is closed on failure. The source error is
/// deliberately discarded so transport bodies and credentials cannot leak.
fn[T, E] result_or_cleanup(
  result : Result[T, E],
  cleanup : () -> Unit,
  safe_error : String,
) -> Result[T, String] {
  match result {
    Ok(value) => Ok(value)
    Err(_) => {
      cleanup()
      Err(safe_error)
    }
  }
}

///|
/// Validate a complete catalog without mutating the live bridge. In addition
/// to ordinary duplicates this catches namespace ambiguity such as server
/// `alpha` + tool `beta__gamma` colliding with server `alpha__beta` + tool
/// `gamma`.
fn plan_catalog(
  entries : Array[CatalogEntry],
  expected_connections : Int,
) -> Result[CatalogPlan, String] {
  if entries.length() != expected_connections {
    return Err("MCP catalog is incomplete")
  }
  let route : Map[String, Int] = Map::from_array([])
  for index, entry in entries {
    if entry.connection_index != index {
      return Err("MCP catalog connection order is invalid")
    }
    for tool in entry.tools {
      if route.contains(tool.name) {
        return Err(
          "MCP namespaced tool collision: '" + diagnostic_label(tool.name) + "'",
        )
      }
      route[tool.name] = entry.connection_index
    }
  }
  Ok(CatalogPlan::{ entries, tool_to_conn: route })
}

///|
/// Run a catalog replacement transaction. The commit callback is invoked only
/// after the whole candidate validates, so an error is a true rollback with
/// no live-state writes.
fn replace_catalog(
  entries : Array[CatalogEntry],
  expected_connections : Int,
  commit : (CatalogPlan) -> Unit,
) -> Result[Unit, String] {
  match plan_catalog(entries, expected_connections) {
    Ok(plan) => {
      commit(plan)
      Ok(())
    }
    Err(message) => Err(message)
  }
}

///|
/// Replace a catalog from injected fetch outcomes. Refresh uses this boundary
/// after remote I/O; tests can inject a late list_tools failure and prove the
/// commit callback is never reached.
fn replace_catalog_from_fetches(
  fetches : Array[Result[CatalogEntry, String]],
  expected_connections : Int,
  commit : (CatalogPlan) -> Unit,
) -> Result[Unit, String] {
  let entries : Array[CatalogEntry] = []
  for fetch in fetches {
    match fetch {
      Ok(entry) => entries.push(entry)
      Err(message) => return Err(message)
    }
  }
  replace_catalog(entries, expected_connections, commit)
}

///|
priv enum MCPCallFailure {
  TransportFailure
  RemoteFailure
}

///|
/// Classify call_tool failures without allowing the caught MCP error/body or
/// tool arguments to cross the adapter boundary.
fn mcp_call_failure(
  failure : MCPCallFailure,
  tool_name : String,
) -> @posoco.RuntimeError {
  let stage = match failure {
    TransportFailure => "transport"
    RemoteFailure => "remote_result"
  }
  @posoco.RuntimeError::InvocationFailed(
    "MCP call failed (stage=" +
    stage +
    ", tool='" +
    diagnostic_label(tool_name) +
    "')",
  )
}

///|
/// Commit a previously validated complete plan. This function performs no
/// fallible work, which makes refresh an all-or-nothing state transition.
fn MCPToolBridge::commit_catalog(
  self : MCPToolBridge,
  plan : CatalogPlan,
) -> Unit {
  for entry in plan.entries {
    self.connections[entry.connection_index].cached_tools = entry.tools
  }
  self.tool_to_conn = plan.tool_to_conn
}

///|
/// ——— MCPToolBridge ———

///| Bridge struct that implements the unified ToolProvider trait (list + execute).

///|
/// Manages multiple MCP server connections with namespaced tool routing.
pub(all) struct MCPToolBridge {
  mut connections : Array[MCPServerConn]
  mut tool_to_conn : Map[String, Int]
}

///|
pub fn MCPToolBridge::new() -> MCPToolBridge {
  { connections: [], tool_to_conn: Map::from_array([]) }
}

///|
/// Connect to an MCP server. Fetches and caches tools during init.
///
/// Must be called before the agent loop starts. Dispatches to connect_http
/// or connect_stdio based on the transport variant (mcp 0.14 API).
pub async fn MCPToolBridge::connect(
  self : MCPToolBridge,
  config : MCPServerConfig,
  group : @async.TaskGroup[Unit],
) -> Result[Unit, String] {
  for conn in self.connections {
    if conn.name == config.name {
      return Err(
        "MCP connection name already exists: '" +
        diagnostic_label(config.name) +
        "'",
      )
    }
  }
  // Create MCP client via connect_* factory (mcp 0.14: connect replaces new+initialize)
  let client_result : Result[@client.MCPClient, @types.MCPError] = match
    config.transport {
    @transport.AnyTransport::StdioClient(t) => {
      let (cmd, args) = stdio_cmd(t)
      @client.MCPClient::connect_stdio(
        cmd~,
        args~,
        name=config.name,
        version="0.1.0",
        group~,
      )
    }
    @transport.AnyTransport::HttpClient(t) => {
      let url = http_url(t)
      @client.MCPClient::connect_http(url~, name=config.name, version="0.1.0")
    }
    _ =>
      return Err(
        "Unsupported transport for '" + diagnostic_label(config.name) + "'",
      )
  }
  let client = match client_result {
    Ok(c) => c
    Err(_) =>
      return Err(
        "MCP connect failed for '" + diagnostic_label(config.name) + "'",
      )
  }
  // Fetch tools (connect_* already did initialize/handshake)
  let tools_result = match
    result_or_cleanup(
      client.list_tools(),
      () => client.close(),
      "MCP list_tools failed for '" + diagnostic_label(config.name) + "'",
    ) {
    Ok(r) => r
    Err(message) => return Err(message)
  }
  // Convert and namespace tools
  let posoco_tools = tools_result.tools.map(fn(t) {
    convert_tool_def(t, config.name)
  })
  // Validate the complete post-connect catalog before storing the client.
  let idx = self.connections.length()
  let catalog_entries : Array[CatalogEntry] = []
  for existing_index, existing in self.connections {
    catalog_entries.push(CatalogEntry::{
      connection_index: existing_index,
      tools: existing.cached_tools,
    })
  }
  catalog_entries.push(CatalogEntry::{
    connection_index: idx,
    tools: posoco_tools,
  })
  let plan = match plan_catalog(catalog_entries, idx + 1) {
    Ok(plan) => plan
    Err(message) => {
      client.close()
      return Err(message)
    }
  }
  // No fallible operation remains after this point.
  let conn : MCPServerConn = {
    name: config.name,
    client,
    cached_tools: posoco_tools,
    _server_info: None, // connect_* already did handshake; server_info not returned by 0.14 API
  }
  self.connections.push(conn)
  self.commit_catalog(plan)
  Ok(())
}

///|
/// Refresh cached tools from all connected MCP servers.
pub async fn MCPToolBridge::refresh_tools(
  self : MCPToolBridge,
) -> Result[Unit, String] {
  let fetches : Array[Result[CatalogEntry, String]] = []
  for i, conn in self.connections {
    match conn.client.list_tools() {
      Ok(result) => {
        let posoco_tools = result.tools.map(fn(t) {
          convert_tool_def(t, conn.name)
        })
        fetches.push(
          Ok(CatalogEntry::{ connection_index: i, tools: posoco_tools }),
        )
      }
      Err(_) => {
        fetches.push(
          Err(
            "MCP refresh list_tools failed for '" +
            diagnostic_label(conn.name) +
            "'",
          ),
        )
        break
      }
    }
  }
  let update = replace_catalog_from_fetches(
    fetches,
    self.connections.length(),
    plan => self.commit_catalog(plan),
  )
  match update {
    Ok(_) => Ok(())
    Err(message) => Err(message)
  }
}

///|
/// Close all MCP connections and clear state.
pub fn MCPToolBridge::close(self : MCPToolBridge) -> Unit {
  for conn in self.connections {
    conn.client.close()
  }
  self.connections = []
  self.tool_to_conn = Map::from_array([])
}

///|
/// ——— Trait Implementations ———

///|
/// ToolProvider: return cached tools from all connected servers.
/// Tools are fetched during connect() and refresh_tools().
pub impl @posoco.ToolProvider for MCPToolBridge with fn list_tools(self) -> Array[
  @posoco.ToolDef,
] {
  let all : Array[@posoco.ToolDef] = []
  for conn in self.connections {
    for t in conn.cached_tools {
      all.push(t)
    }
  }
  all
}

///|
/// ToolProvider (execute): route tool calls to the correct MCP server.
pub impl @posoco.ToolProvider for MCPToolBridge with fn execute(
  self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  // Look up which connection owns this tool
  let conn_idx = match self.tool_to_conn.get(call.name) {
    Some(idx) => idx
    None =>
      raise @posoco.RuntimeError::UnknownTool(
        "Unknown MCP tool: " + diagnostic_label(call.name),
      )
  }
  let conn = self.connections[conn_idx]
  // Strip namespace to get original MCP tool name
  let original_name = strip_namespace(call.name, conn.name)
  // Serialize arguments to JSON string
  let args_str = call.arguments.stringify()
  // Call tool via MCP
  let call_result = conn.client.call_tool(original_name, arguments=args_str) catch {
    _ => raise mcp_call_failure(TransportFailure, original_name)
  }
  let result = match call_result {
    Ok(r) => r
    Err(_) => raise mcp_call_failure(RemoteFailure, original_name)
  }
  let content = convert_content_to_string(result.content)
  @posoco.ToolResult::{ content, structured: None, is_error: result.is_error }
}

///|
pub impl @posoco.Lifecycle for MCPToolBridge with fn on_shutdown(self) -> Unit {
  self.close()
}
