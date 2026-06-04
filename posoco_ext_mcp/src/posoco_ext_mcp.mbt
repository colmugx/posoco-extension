///|
/// posoco_ext_mcp.mbt — Posoco MCP Extension
///
/// Bridges colmugx/mcp client with posoco's unified ToolProvider trait.
/// Enables posoco agents to discover and call tools from MCP servers.

///|
/// ——— Namespace helpers ———

///|
/// Double-underscore separator between server name and tool name.
fn namespaced_tool_name(server_name : String, tool_name : String) -> String {
  "\{server_name}__\{tool_name}"
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
  { connections: [], tool_to_conn: {} }
}

///|
/// Connect to an MCP server. Fetches and caches tools during init.
///
/// Must be called before the agent loop starts. Uses legacy (single-request)
/// mode — no event loop required.
pub async fn MCPToolBridge::connect(
  self : MCPToolBridge,
  config : MCPServerConfig,
  group : @async.TaskGroup[Unit],
) -> Result[Unit, String] {
  // Start STDIO subprocess if needed
  match config.transport {
    @transport.AnyTransport::StdioClient(t) =>
      t.start(group) catch {
        e => return Err("Transport start failed for '\{config.name}': \{e}")
      }
    _ => ()
  }
  // Create MCP client
  let client = @client.MCPClient::new(
    name=config.name,
    version="0.1.0",
    transport=config.transport,
  )
  // Initialize (MCP handshake)
  let server_info = match client.initialize() {
    Ok(info) => info
    Err(e) =>
      return Err("MCP init failed for '\{config.name}': \{e.to_string()}")
  }
  // Fetch tools
  let tools_result = match client.list_tools() {
    Ok(r) => r
    Err(e) =>
      return Err("MCP list_tools failed for '\{config.name}': \{e.to_string()}")
  }
  // Convert and namespace tools
  let posoco_tools = tools_result.tools.map(fn(t) {
    convert_tool_def(t, config.name)
  })
  // Store connection
  let idx = self.connections.length()
  let conn : MCPServerConn = {
    name: config.name,
    client,
    cached_tools: posoco_tools,
    _server_info: Some(server_info),
  }
  self.connections.push(conn)
  // Build reverse map
  for tool in posoco_tools {
    self.tool_to_conn[tool.name] = idx
  }
  Ok(())
}

///|
/// Refresh cached tools from all connected MCP servers.
pub async fn MCPToolBridge::refresh_tools(
  self : MCPToolBridge,
) -> Result[Unit, String] {
  let mut i = 0
  while i < self.connections.length() {
    let conn = self.connections[i]
    // Remove old entries from reverse map
    for old_tool in conn.cached_tools {
      self.tool_to_conn.remove(old_tool.name)
    }
    match conn.client.list_tools() {
      Ok(result) => {
        let posoco_tools = result.tools.map(fn(t) {
          convert_tool_def(t, conn.name)
        })
        conn.cached_tools = posoco_tools
        for tool in posoco_tools {
          self.tool_to_conn[tool.name] = i
        }
      }
      Err(e) =>
        return Err("Refresh failed for '\{conn.name}': \{e.to_string()}")
    }
    i = i + 1
  }
  Ok(())
}

///|
/// Close all MCP connections and clear state.
pub fn MCPToolBridge::close(self : MCPToolBridge) -> Unit {
  for conn in self.connections {
    conn.client.close()
  }
  self.connections = []
  self.tool_to_conn = {}
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
      raise @posoco.RuntimeError::UnknownTool("Unknown MCP tool: " + call.name)
  }
  let conn = self.connections[conn_idx]
  // Strip namespace to get original MCP tool name
  let original_name = strip_namespace(call.name, conn.name)
  // Serialize arguments to JSON string
  let args_str = call.arguments.stringify()
  // Call tool via MCP
  let call_result = conn.client.call_tool(original_name, arguments=args_str) catch {
    e =>
      raise @posoco.RuntimeError::InvocationFailed(
        "MCP transport error for '\{original_name}': \{e}",
      )
  }
  let result = match call_result {
    Ok(r) => r
    Err(e) =>
      raise @posoco.RuntimeError::InvocationFailed(
        "MCP call failed for '\{original_name}': \{e.to_string()}",
      )
  }
  let content = convert_content_to_string(result.content)
  @posoco.ToolResult::{ content, structured: None, is_error: result.is_error }
}

///|
pub impl @posoco.Lifecycle for MCPToolBridge with fn on_shutdown(self) -> Unit {
  self.close()
}
