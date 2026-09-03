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
/// Extract (base_url, bearer token, extra headers) from an HttpClientTransport
/// for connect_http dispatch. The token is empty when the server entry
/// declared none. The extra headers keep their injected order — they are
/// appended to every request the rebuilt transport issues (host-scoped
/// context headers such as `x-lody-mcp-*` ride on this), so this must stay in
/// the dispatch path of every connect.
fn http_connect_params(
  t : @transport.HttpClientTransport,
) -> (String, String, Array[(String, String)]) {
  let token = match t.auth_token {
    Some(token) => token
    None => ""
  }
  (t.base_url, token, t.extra_headers)
}

///|
/// The token that actually reaches the wire: a runtime-injected token (see
/// `set_server_token`) wins over the static mcp.json value; an empty runtime
/// entry never wins.
fn effective_http_token(
  server_tokens : Map[String, String],
  name : String,
  static_token : String,
) -> String {
  match server_tokens.get(name) {
    Some(token) => if token != "" { token } else { static_token }
    None => static_token
  }
}

///|
/// Pull the OAuth protected-resource URI out of a WWW-Authenticate challenge
/// embedded in an error message (`... WWW-Authenticate: Bearer
/// resource_metadata_uri="https://..."`). Only the quoted value survives;
/// the rest of the message must never cross into bridge state.
fn extract_resource_metadata_uri(message : String) -> String? {
  let key = "resource_metadata_uri=\""
  match message.find(key) {
    None => None
    Some(start) =>
      match message[start + key.length():].find("\"") {
        None => None
        Some(offset) => {
          let value_start = start + key.length()
          Some(message[value_start:value_start + offset].to_owned())
        }
      }
  }
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
/// The external input schema is sanitized to the Kernel's supported subset
/// here — see schema_sanitize.mbt for why this cannot wait for the catalog.
fn convert_tool_def(
  mcp_tool : @types.ToolDefinition,
  server_name : String,
) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(
      namespaced_tool_name(server_name, mcp_tool.name),
    ),
    description: mcp_tool.description,
    input_schema: sanitize_tool_schema(mcp_tool.input_schema),
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
/// Authentication posture declared by a server entry. `OAuth` marks entries
/// whose tokens the host acquires at runtime (`set_server_token`) instead of
/// a static `auth_token`.
pub(all) enum ServerAuth {
  NoAuth
  OAuth
} derive(Eq)

///|
/// Configuration for a single MCP server connection.
pub(all) struct MCPServerConfig {
  name : String
  transport : @transport.AnyTransport
  auth : ServerAuth
  /// Protocol era for the client handshake: `Auto` probes and may fall back
  /// to legacy, `Legacy` dials the 2025-11-25 initialize directly (no probe),
  /// `Modern` probes but refuses the legacy fallback.
  era : @client.ProtocolEra
  /// Deadline in milliseconds for one tools/call, tools/list, and the http
  /// connect probe (stdio's era probe keeps the SDK's internal 3000ms).
  /// 0 disables the deadline.
  timeout_ms : Int
  /// Reactive reconnects consumed per execute failure after a wire-level
  /// break or a timeout; 0 disables the retry. Independent of this knob, a
  /// connection whose call timed out is force-reconnected before its next
  /// use (stale-response safety).
  max_reconnects : Int
}

///|
/// Constructor with the documented defaults for the resilience knobs
/// (matching the values mcp.json entries get before M4-style parsing).
pub fn MCPServerConfig::MCPServerConfig(
  name~ : String,
  transport~ : @transport.AnyTransport,
  auth~ : ServerAuth,
  era? : @client.ProtocolEra = @client.ProtocolEra::Auto,
  timeout_ms? : Int = 30_000,
  max_reconnects? : Int = 1,
) -> MCPServerConfig {
  { name, transport, auth, era, timeout_ms, max_reconnects, }
}

///|
/// Internal: a connected MCP server with cached tool list.
struct MCPServerConn {
  name : String
  client : @client.MCPClient
  mut cached_tools : Array[@posoco.ToolDef]
  /// The config this connection was built from; the handshake target for
  /// `reconnect_one`.
  config : MCPServerConfig
  /// A timed-out call may leave a stale response in flight (the SDK's direct
  /// receive path has no response-id matching), so the next use of this
  /// connection must reconnect first.
  mut needs_reconnect : Bool
  /// One in-flight reconnect per connection.
  mut reconnecting : Bool
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
  Ok(CatalogPlan::{ entries, tool_to_conn: route, })
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
priv enum ListToolsFailure {
  TimedOut(Int)
  Failed
}

///|
/// One `tools/list` round trip under `timeout_ms` (0 disables the deadline),
/// with tools converted to the namespaced Posoco form. Cancellation is
/// re-raised untouched. `record_challenges` mirrors the connect-path behavior
/// of capturing a 401 challenge from the raw error before it is discarded.
async fn MCPToolBridge::fetch_tools(
  self : MCPToolBridge,
  server : String,
  client : @client.MCPClient,
  timeout_ms : Int,
  record_challenges? : Bool = true,
) -> Result[Array[@posoco.ToolDef], ListToolsFailure] {
  let attempt = async fn() {
    match client.list_tools() {
      Ok(result) => Ok(result.tools.map(fn(t) { convert_tool_def(t, server) }))
      Err(e) => {
        if record_challenges {
          self.record_auth_challenge(server, e.message())
        }
        Err(ListToolsFailure::Failed)
      }
    }
  }
  if timeout_ms > 0 {
    @async.with_timeout(timeout_ms, attempt) catch {
      error => {
        if @async.is_being_cancelled() {
          raise error
        }
        // Only the with_timeout sentinel arrives here: list_tools maps every
        // transport raise into its Result.
        Err(ListToolsFailure::TimedOut(timeout_ms))
      }
    }
  } else {
    attempt()
  }
}

///|
/// One `tools/call` attempt under the connection's `timeout_ms` (0 disables
/// the deadline). Cancellation is re-raised untouched: a cancellation
/// injected at a suspension point must not be re-labeled into an
/// InvocationFailed and lose the identity the run loop's abort depends on
/// (same rule as the colmugx/mcp transport catches). A fired deadline
/// classifies as `TimedOut`, a server JSON-RPC error as `RemoteFailure`, and
/// every wire-level break as `TransportFailure`.
async fn call_tool_attempt(
  conn : MCPServerConn,
  tool_name : String,
  args_str : String,
) -> Result[@client.CallToolResult, MCPCallFailure] {
  let attempt = async fn() {
    match conn.client.call_tool(tool_name, arguments=args_str) {
      Ok(result) => Ok(result)
      Err(e) =>
        if is_connection_level_error(e) {
          Err(MCPCallFailure::TransportFailure)
        } else {
          Err(MCPCallFailure::RemoteFailure)
        }
    }
  }
  if conn.config.timeout_ms > 0 {
    @async.with_timeout(conn.config.timeout_ms, attempt) catch {
      error => {
        if @async.is_being_cancelled() {
          raise error
        }
        Err(MCPCallFailure::TimedOut(conn.config.timeout_ms))
      }
    }
  } else {
    attempt()
  }
}

///|
priv enum MCPCallFailure {
  TransportFailure
  RemoteFailure
  TimedOut(Int)
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
    TimedOut(_) => "timeout"
  }
  let detail = match failure {
    TimedOut(ms) => ", timeout_ms=\{ms}"
    _ => ""
  }
  @posoco.RuntimeError::InvocationFailed(
    "MCP call failed (stage=\{stage}\{detail}, tool='\{@devkit.sanitize_label(tool_name)}')",
  )
}

///|
/// Wire-level breaks a fresh connection can fix. The SDK reports send/receive
/// breaks as `InternalError` with these message prefixes (client.mbt
/// `send_request`, legacy_client.mbt `send_raw`) or as wrapped
/// `TransportError` values. Server JSON-RPC errors ("Server error: ...") and
/// parse failures are remote problems, not connection problems.
fn is_connection_level_error(e : @types.MCPError) -> Bool {
  match e {
    @types.TransportError(_) => true
    @types.InternalError(message) =>
      message.has_prefix("Send failed") ||
      message.has_prefix("Receive failed") ||
      message.has_prefix("Connection closed") ||
      message.has_prefix("Response timeout")
    _ => false
  }
}

///|
/// Sanitized caller-facing message for a failed tools/list. The timeout
/// variant stays distinguishable from ordinary transport failures.
fn list_tools_failure_message(
  prefix : String,
  server : String,
  failure : ListToolsFailure,
) -> String {
  match failure {
    ListToolsFailure::TimedOut(ms) =>
      "\{prefix} for '\{@devkit.sanitize_label(server)}' (stage=timeout, timeout_ms=\{ms})"
    ListToolsFailure::Failed =>
      "\{prefix} for '\{@devkit.sanitize_label(server)}'"
  }
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
  /// Runtime-injected http auth tokens; take precedence over static tokens
  /// from mcp.json for the same server name.
  server_tokens : Map[String, String]
  /// Resource metadata URIs captured from 401 challenges, by server name.
  auth_challenges : Map[String, String]
  /// Every server config the bridge has seen (discovered or connected);
  /// the lookup table for `reconnect_server`.
  configs : Map[String, MCPServerConfig]
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
    server_tokens: Map::from_array([]),
    auth_challenges: Map::from_array([]),
    configs: Map::from_array([]),
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
    Ok(pending) => {
      // Pending configs are registered now so `reconnect_server` can retry a
      // server whose first activation failed (e.g. before an OAuth login).
      let configs : Map[String, MCPServerConfig] = Map::from_array([])
      for config in pending {
        configs[config.name] = config
      }
      Ok({
        connections: [],
        tool_to_conn: Map::from_array([]),
        mode,
        pending,
        group: None,
        activated: false,
        catalog_revision: 0,
        startup_failures: [],
        server_tokens: Map::from_array([]),
        auth_challenges: Map::from_array([]),
        configs,
      })
    }
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
/// tools during init. Must be called before the agent loop starts. A
/// successful connect commits the catalog and bumps the revision, so a wired
/// `McpCatalogSource` re-reads at the next turn (same contract as
/// `refresh_tools`).
pub async fn MCPToolBridge::connect(
  self : MCPToolBridge,
  config : MCPServerConfig,
  group : @async.TaskGroup[Unit],
) -> Result[Unit, String] {
  match self.connect_with_group(config, Some(group)) {
    Ok(_) => {
      self.catalog_revision = self.catalog_revision + 1
      Ok(())
    }
    Err(message) => Err(message)
  }
}

///|
/// Build the underlying client for one server config: the connect_* factory
/// handshake, with the http connect (era probe and legacy fallback) bounded
/// by `timeout_ms` (0 disables it; stdio keeps the SDK's internal 3000ms era
/// probe and is not double-wrapped). Auth challenges are captured from the
/// raw connect error before it is discarded.
async fn MCPToolBridge::open_client(
  self : MCPToolBridge,
  config : MCPServerConfig,
  group : @async.TaskGroup[Unit]?,
) -> Result[@client.MCPClient, String] {
  match config.transport {
    @transport.AnyTransport::StdioClient(t) => {
      let (cmd, args, extra_env) = stdio_cmd(t)
      match group {
        Some(group) =>
          match
            @client.MCPClient::connect_stdio(
              cmd~,
              args~,
              name=config.name,
              version="0.1.0",
              extra_env~,
              group~,
              era=config.era,
            ) {
            Ok(client) => Ok(client)
            Err(e) => {
              self.record_auth_challenge(config.name, e.message())
              Err(
                "MCP connect failed for '\{@devkit.sanitize_label(config.name)}' (stage=handshake, error=\{e.message()})",
              )
            }
          }
        None =>
          Err(
            "MCP connect needs a task group (call attach first) for '\{@devkit.sanitize_label(config.name)}'",
          )
      }
    }
    @transport.AnyTransport::HttpClient(t) => {
      let (url, static_token, extra_headers) = http_connect_params(t)
      let auth_token = effective_http_token(
        self.server_tokens,
        config.name,
        static_token,
      )
      let handshake = async fn() {
        match
          @client.MCPClient::connect_http(
            url~,
            name=config.name,
            version="0.1.0",
            auth_token~,
            extra_headers~,
            era=config.era,
          ) {
          Ok(client) => Ok(client)
          Err(e) => {
            self.record_auth_challenge(config.name, e.message())
            Err(
              "MCP connect failed for '\{@devkit.sanitize_label(config.name)}' (stage=handshake, error=\{e.message()})",
            )
          }
        }
      }
      if config.timeout_ms > 0 {
        @async.with_timeout(config.timeout_ms, handshake) catch {
          error => {
            if @async.is_being_cancelled() {
              raise error
            }
            Err(
              "MCP connect failed for '\{@devkit.sanitize_label(config.name)}' (stage=timeout, timeout_ms=\{config.timeout_ms})",
            )
          }
        }
      } else {
        handshake()
      }
    }
    _ =>
      Err("Unsupported transport for '\{@devkit.sanitize_label(config.name)}'")
  }
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
  let client = match self.open_client(config, group) {
    Ok(client) => client
    Err(message) => return Err(message)
  }
  // Fetch tools (connect_* already did initialize/handshake). On failure the
  // freshly connected client is closed inline (close is async in mcp 0.15, so
  // it cannot live in a sync cleanup callback); the source error is discarded
  // so transport bodies and credentials cannot leak.
  let tools = match self.fetch_tools(config.name, client, config.timeout_ms) {
    Ok(tools) => tools
    Err(failure) => {
      client.close()
      return Err(
        list_tools_failure_message(
          "MCP list_tools failed",
          config.name,
          failure,
        ),
      )
    }
  }
  match
    self.commit_connection(config, client, tools, self.connections.length()) {
    Ok(_) => Ok(())
    Err(message) => {
      client.close()
      Err(message)
    }
  }
}

///|
/// Shared "validate + commit" tail of every connect path (fresh connect and
/// in-place reconnect). Validates the candidate catalog for slot `idx`
/// against the other live connections; only after validation stores the
/// client, writes the connection in place (appending when `idx` is one past
/// the end), swaps the routing map, and registers the config. The caller
/// closes `client` when this returns Err — no live state is touched on a
/// failed validation.
fn MCPToolBridge::commit_connection(
  self : MCPToolBridge,
  config : MCPServerConfig,
  client : @client.MCPClient,
  tools : Array[@posoco.ToolDef],
  idx : Int,
) -> Result[Unit, String] {
  let appending = idx == self.connections.length()
  let catalog_entries : Array[CatalogEntry] = []
  for existing_index, existing in self.connections {
    catalog_entries.push(CatalogEntry::{
      connection_index: existing_index,
      tools: if existing_index == idx {
        tools
      } else {
        existing.cached_tools
      },
    })
  }
  if appending {
    catalog_entries.push(CatalogEntry::{ connection_index: idx, tools, })
  }
  let expected = self.connections.length() + (if appending { 1 } else { 0 })
  let plan = match plan_catalog(catalog_entries, expected) {
    Ok(plan) => plan
    Err(message) => return Err(message)
  }
  // No fallible operation remains after this point.
  let conn : MCPServerConn = {
    name: config.name,
    client,
    cached_tools: tools,
    config,
    needs_reconnect: false,
    reconnecting: false,
    _server_info: None, // connect_* already did handshake; server_info not returned by 0.14 API
  }
  if appending {
    self.connections.push(conn)
  } else {
    self.connections[idx] = conn
  }
  self.commit_catalog(plan)
  // Register/update after a successful connect: host-constructed configs
  // (explicit `connect`) become the retry target for `reconnect_server`.
  self.configs[config.name] = config
  Ok(())
}

///|
/// Refresh cached tools from all connected MCP servers.
pub async fn MCPToolBridge::refresh_tools(
  self : MCPToolBridge,
) -> Result[Unit, String] {
  let fetches : Array[Result[CatalogEntry, String]] = []
  for i, _conn in self.connections {
    // A connection whose last call timed out may deliver a stale response to
    // the next read (no response-id matching in the SDK's direct receive
    // path); reconnect first so the refreshed list cannot be built from a
    // misattributed reply.
    if self.connections[i].needs_reconnect && !self.connections[i].reconnecting {
      let _ = self.reconnect_one(i)
    }
    let conn = self.connections[i]
    match
      self.fetch_tools(
        conn.name,
        conn.client,
        conn.config.timeout_ms,
        record_challenges=false,
      ) {
      Ok(tools) =>
        fetches.push(Ok(CatalogEntry::{ connection_index: i, tools, }))
      Err(failure) => {
        fetches.push(
          Err(
            list_tools_failure_message(
              "MCP refresh list_tools failed",
              conn.name,
              failure,
            ),
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
/// Store the OAuth protected-resource URI advertised by a failed connect, if
/// the error carried a challenge. Only the URI is persisted — never the
/// error body, headers, or server text.
fn MCPToolBridge::record_auth_challenge(
  self : MCPToolBridge,
  server : String,
  error_message : String,
) -> Unit {
  match extract_resource_metadata_uri(error_message) {
    Some(uri) => self.auth_challenges[server] = uri
    None => ()
  }
}

///|
/// Inject or clear a runtime http token for one server. An empty token
/// clears the entry so the static mcp.json value applies again.
pub fn MCPToolBridge::set_server_token(
  self : MCPToolBridge,
  server : String,
  token : String,
) -> Unit {
  if token == "" {
    self.server_tokens.remove(server)
  } else {
    self.server_tokens[server] = token
  }
}

///|
/// The OAuth protected-resource URI captured from this server's latest 401
/// challenge, if any. The host starts its OAuth flow from here.
pub fn MCPToolBridge::auth_challenge(
  self : MCPToolBridge,
  server : String,
) -> String? {
  self.auth_challenges.get(server)
}

///|
/// Every known server config whose declared auth posture matches, in config
/// map iteration order. The host's startup pass over OAuth servers ("inject
/// a stored token, else wait for an explicit login") iterates exactly this
/// list.
pub fn MCPToolBridge::servers_by_auth(
  self : MCPToolBridge,
  auth : ServerAuth,
) -> Array[String] {
  let names : Array[String] = []
  for _, config in self.configs {
    if config.auth == auth {
      names.push(config.name)
    }
  }
  names
}

///|
/// Reconnect one server (e.g. after the host injected a fresh token). The
/// old connection is removed first, so a failed re-connect degrades to "this
/// server's tools are absent" instead of a stale client; routing is replayed
/// from the surviving connections so no route ever points at a stale index.
pub async fn MCPToolBridge::reconnect_server(
  self : MCPToolBridge,
  server : String,
) -> Result[Unit, String] {
  let config = match self.configs.get(server) {
    Some(config) => config
    None =>
      return Err(
        "MCP server not configured: '\{@devkit.sanitize_label(server)}'",
      )
  }
  let mut old_index = -1
  for i, conn in self.connections {
    if conn.name == server {
      old_index = i
      break
    }
  }
  if old_index >= 0 {
    self.connections[old_index].client.close()
    let _ = self.connections.remove(old_index)
  }
  let routes : Map[String, Int] = Map::from_array([])
  for i, conn in self.connections {
    for tool in conn.cached_tools {
      routes[tool.name.to_string()] = i
    }
  }
  self.tool_to_conn = routes
  match self.connect_with_group(config, self.group) {
    Ok(_) => {
      self.catalog_revision = self.catalog_revision + 1
      Ok(())
    }
    Err(message) => Err(message)
  }
}

///|
/// Reconnect exactly one connection in place: close the old client, redo the
/// connect handshake from the stored config, re-fetch the tool list, and —
/// only after the candidate catalog validates — replace the connection at
/// `conn_idx` and bump the catalog revision. Connection indices and routing
/// survive unchanged (`tool_to_conn` still maps to `conn_idx`). A failed
/// reconnect leaves the old (closed) connection in place, so later calls fail
/// fast instead of hanging. Guarded by `reconnecting`: at most one in-flight
/// reconnect per connection, and callers consume at most one per failure.
async fn MCPToolBridge::reconnect_one(
  self : MCPToolBridge,
  conn_idx : Int,
) -> Result[Unit, String] {
  if conn_idx >= self.connections.length() {
    return Err("MCP connection is no longer present")
  }
  if self.connections[conn_idx].reconnecting {
    return Err(
      "MCP reconnect already in progress for '\{@devkit.sanitize_label(self.connections[conn_idx].name)}'",
    )
  }
  let config = self.connections[conn_idx].config
  self.connections[conn_idx].reconnecting = true
  // The connection is either replaced by a fresh one or left closed after
  // this attempt; neither state can misattribute a stale response, so the
  // flag is consumed regardless of the outcome.
  self.connections[conn_idx].needs_reconnect = false
  defer (if conn_idx < self.connections.length() {
    self.connections[conn_idx].reconnecting = false
  })
  self.connections[conn_idx].client.close()
  let client = match self.open_client(config, self.group) {
    Ok(client) => client
    Err(message) => return Err(message)
  }
  let tools = match self.fetch_tools(config.name, client, config.timeout_ms) {
    Ok(tools) => tools
    Err(failure) => {
      client.close()
      return Err(
        list_tools_failure_message(
          "MCP reconnect list_tools failed",
          config.name,
          failure,
        ),
      )
    }
  }
  match self.commit_connection(config, client, tools, conn_idx) {
    Ok(_) => Ok(())
    Err(message) => {
      client.close()
      Err(message)
    }
  }
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
  let attempted = self.invoke_mcp_tool(conn_idx, original_name, args_str) catch {
    _ =>
      // invoke_mcp_tool raises only while the task is being cancelled (its
      // timeout wrapper re-raises cancellation untouched, and no
      // reconnect/retry runs on that path). This trait slot only allows
      // RuntimeError, so the raw cancellation error cannot pass through
      // unchanged: raise a dedicated marker instead of re-labeling it as a
      // transport/remote failure — the sticky cancel flag checked by the
      // runtime seam still carries the abort identity.
      if @async.is_being_cancelled() {
        raise @posoco.RuntimeError::InvocationFailed("MCP tool call cancelled")
      } else {
        raise mcp_call_failure(TransportFailure, original_name)
      }
  }
  let result = match attempted {
    Ok(result) => result
    Err(failure) => {
      if failure is MCPCallFailure::TimedOut(_) {
        // The abandoned request may still deliver a stale response on this
        // connection (no response-id matching in the SDK's direct receive
        // path), so the next use must reconnect first.
        self.connections[conn_idx].needs_reconnect = true
      }
      raise mcp_call_failure(failure, original_name)
    }
  }
  let content = convert_content_to_string(result.content)
  if result.is_error {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
  } else {
    @posoco.ToolOutcome::Success(content~, structured=None)
  }
}

///|
/// One logical MCP tool invocation: a timeout-bounded `tools/call` attempt,
/// plus at most one reactive reconnect-and-retry. Connection-level failures
/// and timeouts are reconnect-eligible (when `max_reconnects > 0` and no
/// reconnect is already in flight for the connection); server JSON-RPC
/// errors never are. Reconnect and retry failures surface the original
/// failure.
async fn MCPToolBridge::invoke_mcp_tool(
  self : MCPToolBridge,
  conn_idx : Int,
  tool_name : String,
  args_str : String,
) -> Result[@client.CallToolResult, MCPCallFailure] {
  // A connection marked unhealthy by an earlier timeout is force-reconnected
  // before reuse, whatever `max_reconnects` says: reusing it could hand a
  // stale response to this call.
  if self.connections[conn_idx].needs_reconnect &&
    !self.connections[conn_idx].reconnecting {
    let _ = self.reconnect_one(conn_idx)
  }
  match call_tool_attempt(self.connections[conn_idx], tool_name, args_str) {
    Ok(result) => Ok(result)
    Err(failure) => {
      let eligible = match failure {
        MCPCallFailure::RemoteFailure => false
        MCPCallFailure::TransportFailure | MCPCallFailure::TimedOut(_) => true
      }
      if eligible &&
        self.connections[conn_idx].config.max_reconnects > 0 &&
        !self.connections[conn_idx].reconnecting {
        match self.reconnect_one(conn_idx) {
          Err(_) => Err(failure)
          Ok(_) =>
            call_tool_attempt(self.connections[conn_idx], tool_name, args_str)
        }
      } else {
        Err(failure)
      }
    }
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
/// Ports the bridge contributes: tools (ToolProvider), lifecycle (lazy
/// activation + shutdown close), and the host-facing `mcp` status command
/// on the same struct.
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
    commands: [self],
    ui: [],
    prompt_contributors: [],
    requires: [],
  }
}

///|
pub extend MCPToolBridge with @posoco.Extension::{extension_id, manifest}

///|
pub extend MCPToolBridge with @posoco.Lifecycle::{on_start, on_shutdown}
