///|
/// posoco_ext_mcp.mbt — Posoco MCP Extension
///
/// Bridges colmugx/mcp client with posoco's unified ToolProvider trait.
/// Enables posoco agents to discover and call tools from MCP servers.

///|
/// Extract (cmd, args, extra_env) from a StdioClientTransport for
/// connect_stdio dispatch.
fn stdio_cmd(
  t : @transport.StdioClientTransport,
) -> (String, Array[String], Map[String, String]) {
  (t.cmd, t.args, t.extra_env)
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
fn strip_namespace(namespaced : String, server_name : String) -> String {
  let prefix = "\{server_name}__"
  if namespaced.has_prefix(prefix) {
    namespaced[prefix.length():].to_owned()
  } else {
    namespaced
  }
}

///|
/// Convert MCP ToolDefinition to Posoco ToolDef with namespace prefix.
fn convert_tool_def(
  mcp_tool : @types.ToolDefinition,
  server_name : String,
) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(
      namespaced_tool_name(server_name, mcp_tool.name),
    ),
    description: mcp_tool.description,
    input_schema: mcp_tool.input_schema,
    owner: @posoco.OwnerId::unchecked("posoco_ext_mcp"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_mcp:\{server_name}"),
  }
}

///|
/// Convert MCP ContentItem array to a plain text string.
fn convert_content_to_string(items : Array[@types.ContentItem]) -> String {
  items
  .map(fn(item) {
    match item {
      @types.ContentItem::Text(t) => t
      @types.ContentItem::Image(data, mime_type~) =>
        "[Image: \{mime_type}, \{data.length()} chars]"
      @types.ContentItem::ResourceLink(uri) => "[Resource: \{uri}]"
      @types.ContentItem::EmbeddedResource(content) =>
        match content {
          @types.EmbeddedResourceContent::Text(t, uri~, ..) =>
            "[Resource \{uri}]: \{t}"
          @types.EmbeddedResourceContent::Blob(b, uri~, ..) =>
            "[Resource \{uri}]: [blob \{b.length()} chars]"
        }
    }
  })
  .join("\n")
}

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
      let tool_name = tool.name.to_string()
      if route.contains(tool_name) {
        return Err(
          "MCP namespaced tool collision: '\{@devkit.sanitize_label(tool_name)}'",
        )
      }
      route[tool_name] = entry.connection_index
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
    "MCP call failed (stage=\{stage}, tool='\{@devkit.sanitize_label(tool_name)}')",
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

///| Bridge struct that implements the unified ToolProvider trait (list + execute).

///|
/// Manages multiple MCP server connections with namespaced tool routing.
///
/// Servers come either from explicit `connect` calls or from self-governed
/// mcp.json discovery (`discover`); discovered servers activate through
/// `attach` + `activate` in the mode chosen at discovery time.
pub(all) struct MCPToolBridge {
  mut connections : Array[MCPServerConn]
  mut tool_to_conn : Map[String, Int]
  /// Activation posture chosen at discovery time; never changes after.
  mode : LoadMode
  /// Discovered-but-not-yet-connected server configs (mcp.json path).
  pending : Array[MCPServerConfig]
  /// Host-provided long-lived task group; stdio servers need it to spawn
  /// their child process. `None` until `attach`.
  mut group : @async.TaskGroup[Unit]?
  /// Flips on the first `activate`; guards the Lazy on_start hook.
  mut activated : Bool
  /// Change signal for the runtime-seam catalog source. Bumped once per
  /// activation and per successful refresh, so prompt boundaries re-read.
  mut catalog_revision : Int
  /// (server, sanitized reason) for servers that failed activation.
  startup_failures : Array[(String, String)]
}

///|
pub fn MCPToolBridge::MCPToolBridge() -> MCPToolBridge {
  {
    connections: [],
    tool_to_conn: Map::from_array([]),
    mode: LoadMode::Eager,
    pending: [],
    group: None,
    activated: false,
    catalog_revision: 0,
    startup_failures: [],
  }
}

///|
/// Discover servers from mcp.json (`<cwd>/.mcp.json` overriding
/// `<home>/.cetas/mcp.json`) and return a bridge ready to `attach` +
/// `activate`. A malformed file fails loud here — before any connection is
/// attempted — with a sanitized message.
pub async fn MCPToolBridge::discover(
  cwd~ : String,
  home~ : String,
  mode? : LoadMode = LoadMode::Eager,
) -> Result[MCPToolBridge, String] noraise {
  match discover_mcp_servers(cwd, home) {
    Ok(pending) =>
      Ok({
        connections: [],
        tool_to_conn: Map::from_array([]),
        mode,
        pending,
        group: None,
        activated: false,
        catalog_revision: 0,
        startup_failures: [],
      })
    Err(message) => Err(message)
  }
}

///|
/// Hand the bridge the host's long-lived task group. stdio servers spawn
/// their child process on it, so the group must outlive every connection —
/// a temporary group would SIGTERM the children when it closes.
pub fn MCPToolBridge::attach(
  self : MCPToolBridge,
  group : @async.TaskGroup[Unit],
) -> Unit {
  self.group = Some(group)
}

///|
/// Connect every discovered server. Per-server failures are returned (and
/// recorded) instead of raised: a down server degrades to "its tools are
/// absent from the catalog", it never aborts the host. Eager hosts call
/// this right after `attach`; in Lazy mode the bridge activates itself in
/// `Lifecycle::on_start` (before the first turn's catalog read).
pub async fn MCPToolBridge::activate(
  self : MCPToolBridge,
) -> Array[(String, String)] {
  self.activated = true
  for config in self.pending {
    match self.connect_with_group(config, self.group) {
      Ok(_) => ()
      Err(message) => self.startup_failures.push((config.name, message))
    }
  }
  // One bump per activation attempt: the catalog source re-reads at the
  // next prompt boundary even when every server failed (empty = honest).
  self.catalog_revision = self.catalog_revision + 1
  self.startup_failures
}

///|
/// Servers that failed the latest activation, as (name, sanitized reason).
pub fn MCPToolBridge::failures(self : MCPToolBridge) -> Array[(String, String)] {
  self.startup_failures
}

///|
/// Connect to an MCP server with an explicit task group. Fetches and caches
/// tools during init. Must be called before the agent loop starts.
pub async fn MCPToolBridge::connect(
  self : MCPToolBridge,
  config : MCPServerConfig,
  group : @async.TaskGroup[Unit],
) -> Result[Unit, String] {
  self.connect_with_group(config, Some(group))
}

///|
/// Core connect: `group` may be `None` only for http servers (stdio spawns a
/// child process on the group and cannot proceed without one).
async fn MCPToolBridge::connect_with_group(
  self : MCPToolBridge,
  config : MCPServerConfig,
  group : @async.TaskGroup[Unit]?,
) -> Result[Unit, String] {
  for conn in self.connections {
    if conn.name == config.name {
      return Err(
        "MCP connection name already exists: '\{@devkit.sanitize_label(config.name)}'",
      )
    }
  }
  // Create MCP client via connect_* factory (mcp 0.15: connect replaces new+initialize)
  let client_result : Result[@client.MCPClient, @types.MCPError] = match
    config.transport {
    @transport.AnyTransport::StdioClient(t) => {
      let (cmd, args, extra_env) = stdio_cmd(t)
      match group {
        Some(group) =>
          @client.MCPClient::connect_stdio(
            cmd~,
            args~,
            name=config.name,
            version="0.1.0",
            extra_env~,
            group~,
          )
        None =>
          return Err(
            "MCP connect needs a task group (call attach first) for '\{@devkit.sanitize_label(config.name)}'",
          )
      }
    }
    @transport.AnyTransport::HttpClient(t) => {
      let url = http_url(t)
      @client.MCPClient::connect_http(url~, name=config.name, version="0.1.0")
    }
    _ =>
      return Err(
        "Unsupported transport for '\{@devkit.sanitize_label(config.name)}'",
      )
  }
  let client = match client_result {
    Ok(c) => c
    Err(_) =>
      return Err(
        "MCP connect failed for '\{@devkit.sanitize_label(config.name)}'",
      )
  }
  // Fetch tools (connect_* already did initialize/handshake). On failure the
  // freshly connected client is closed inline (close is async in mcp 0.15, so
  // it cannot live in a sync cleanup callback); the source error is discarded
  // so transport bodies and credentials cannot leak.
  let tools_result = match client.list_tools() {
    Ok(result) => result
    Err(_) => {
      client.close()
      return Err(
        "MCP list_tools failed for '\{@devkit.sanitize_label(config.name)}'",
      )
    }
  }
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
            "MCP refresh list_tools failed for '\{@devkit.sanitize_label(conn.name)}'",
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
    Ok(_) => {
      // A committed refresh changes the advertised tool set; bump the
      // revision so a wired McpCatalogSource is re-read at the next turn.
      self.catalog_revision = self.catalog_revision + 1
      Ok(())
    }
    Err(message) => Err(message)
  }
}

///|
/// Close all MCP connections and clear state. Async since mcp 0.15: the
/// underlying client close performs I/O and cannot block the caller.
pub async fn MCPToolBridge::close(self : MCPToolBridge) -> Unit {
  for conn in self.connections {
    conn.client.close()
  }
  self.connections = []
  self.tool_to_conn = Map::from_array([])
}

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
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let call_name = call.name.to_string()
  let conn_idx = match self.tool_to_conn.get(call_name) {
    Some(idx) => idx
    None =>
      raise @posoco.RuntimeError::UnknownTool(
        "Unknown MCP tool: \{@devkit.sanitize_label(call_name)}",
      )
  }
  let conn = self.connections[conn_idx]
  let original_name = strip_namespace(call_name, conn.name)
  let args_str = call.arguments.stringify()
  let call_result = conn.client.call_tool(original_name, arguments=args_str) catch {
    _ => raise mcp_call_failure(TransportFailure, original_name)
  }
  let result = match call_result {
    Ok(r) => r
    Err(_) => raise mcp_call_failure(RemoteFailure, original_name)
  }
  let content = convert_content_to_string(result.content)
  if result.is_error {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
  } else {
    @posoco.ToolOutcome::Success(content~, structured=None)
  }
}

///|
/// Lazy activation point: the first turn's `on_start` runs before that
/// turn's catalog read, so servers connected here are advertised in the
/// same turn through a wired `McpCatalogSource`. Activation failures are
/// recorded, never raised — a down server must not kill the first turn.
pub impl @posoco.Lifecycle for MCPToolBridge with fn on_start(self) -> Unit {
  if self.mode is Lazy && !self.activated {
    let _ = self.activate()
  }
}

///|
/// The async slot accepts this impl: the body's async close call is inferred.
pub impl @posoco.Lifecycle for MCPToolBridge with fn on_shutdown(self) -> Unit {
  self.close()
}

///|
pub impl @posoco.Extension for MCPToolBridge with fn extension_id(
  _self : MCPToolBridge,
) -> String {
  "posoco_ext_mcp"
}

///|
/// Ports the bridge contributes: tools (ToolProvider) and lifecycle (lazy
/// activation + shutdown close) on the same struct.
pub impl @posoco.Extension for MCPToolBridge with fn manifest(
  self : MCPToolBridge,
) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_mcp",
    models: [],
    tools: [self],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [self],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
pub extend MCPToolBridge with @posoco.Extension::{extension_id, manifest}

///|
pub extend MCPToolBridge with @posoco.Lifecycle::{on_start, on_shutdown}
