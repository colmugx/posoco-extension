///|
/// Bridges the colmugx/mcp client with posoco's unified ToolProvider trait.

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
/// context headers ride on this), so this must stay in the dispatch path of
/// every connect.
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
const MCP_TOOL_DESCRIPTION_CHARS = 300

///|
const MCP_SUCCESS_OUTPUT_CHARS = 40_000

///|
const MCP_ERROR_OUTPUT_CHARS = 8_000

///|
fn mcp_model_text(text : String, limit : Int) -> (String, Bool) {
  let clipped = @devkit.truncate_chars(text, limit)
  if clipped == text {
    (clipped, false)
  } else {
    (clipped + "\n…[cut]", true)
  }
}

///|
fn mcp_outcome_structured(truncated : Bool) -> Json? {
  if truncated {
    Some(Json::object({ "truncated": Json::boolean(true) }))
  } else {
    None
  }
}

///|
fn mcp_tool_description(description : String) -> String {
  let clipped = @devkit.truncate_chars(description, MCP_TOOL_DESCRIPTION_CHARS)
  if clipped == description { clipped } else { clipped + "…" }
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
    description: mcp_tool_description(mcp_tool.description),
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
pub extend ServerAuth with Eq::{not_equal, equal}

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
/// (the same values mcp.json parsing applies).
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
/// Internal: one slot in the connection registry. `client` is the published
/// mirror of the connection actor's current-generation client — written only
/// inside the synchronous commit/retire seams (single-writer discipline) —
/// and is `None` on a retired slot (the server is absent) while the slot
/// itself, its name, and its config keep their position so routing indexes
/// never drift onto a neighbor. `actor` is present exactly when `client` is:
/// spawned when a commit installs a connection, closed and detached when the
/// slot retires. `epoch` is bumped by every retire; an in-place refill
/// carries the epoch it observed, so a refill racing another retire+refill
/// of the same slot loses honestly instead of clobbering the winner.
struct MCPServerConn {
  name : String
  mut client : @client.MCPClient?
  mut actor : ConnActor[@client.MCPClient]?
  mut cached_tools : Array[@posoco.ToolDef]
  /// The config this connection was built from; the handshake target for
  /// `reconnect_one`.
  config : MCPServerConfig
  mut epoch : Int
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
/// One `tools/call` attempt on an explicitly held client under `timeout_ms`
/// (0 disables the deadline). Cancellation is re-raised untouched: a
/// cancellation injected at a suspension point must not be re-labeled into
/// an InvocationFailed and lose the identity the run loop's abort depends on
/// (same rule as the colmugx/mcp transport catches). A fired deadline
/// classifies as `TimedOut`, a server JSON-RPC error as `RemoteFailure`, and
/// every wire-level break as `TransportFailure`.
async fn call_tool_attempt(
  client : @client.MCPClient,
  timeout_ms : Int,
  tool_name : String,
  args_str : String,
) -> Result[@client.CallToolResult, MCPCallFailure] {
  let attempt = async fn() {
    match client.call_tool(tool_name, arguments=args_str) {
      Ok(result) => Ok(result)
      Err(e) =>
        if is_connection_level_error(e) {
          Err(MCPCallFailure::TransportFailure)
        } else {
          Err(MCPCallFailure::RemoteFailure)
        }
    }
  }
  if timeout_ms > 0 {
    @async.with_timeout(timeout_ms, attempt) catch {
      error => {
        if @async.is_being_cancelled() {
          raise error
        }
        Err(MCPCallFailure::TimedOut(timeout_ms))
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
/// Honest message for a connect path that finds no task group: the group
/// contract requires one for every connection creation — an explicit
/// parameter or an `attach`ed bridge group.
fn missing_task_group_message(name : String) -> String {
  "MCP connect needs a task group (call attach first) for '\{@devkit.sanitize_label(name)}'"
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
/// Live-slot read: `Some` only when `idx` is in bounds and the slot holds a
/// connection (not retired). Every read that happens after an await goes
/// through this — plus the name check in `live_slot_for` — so a stale index
/// can never reach a neighbor slot.
fn MCPToolBridge::live_slot(self : MCPToolBridge, idx : Int) -> MCPServerConn? {
  if idx >= self.connections.length() {
    return None
  }
  match self.connections[idx].client {
    Some(_) => Some(self.connections[idx])
    None => None
  }
}

///|
/// Post-await routing guard: the slot must still be in bounds, hold a live
/// client, and still belong to the server this call started against.
/// Anything else is an honest failure — the caller never retries against a
/// slot whose content changed under it.
fn MCPToolBridge::live_slot_for(
  self : MCPToolBridge,
  idx : Int,
  server : String,
) -> MCPServerConn? {
  match self.live_slot(idx) {
    Some(conn) => if conn.name == server { Some(conn) } else { None }
    None => None
  }
}

///|
/// Retire one slot in place: close the connection actor (its mailbox then
/// refuses reports — a still-running reconnect runner on that actor loses
/// structurally instead of clobbering the refill), detach the client mirror,
/// drop the cached tool list, bump the slot's epoch, and replay routing from
/// the live slots. The caller closes the detached client first (close
/// performs I/O and needs an async context). Slot positions never change, so
/// in-flight readers re-validating an index can never land on a neighbor,
/// and a slot that is never refilled degrades to "that server's tools are
/// absent".
fn MCPToolBridge::retire_slot(self : MCPToolBridge, slot : Int) -> Unit {
  if slot >= self.connections.length() {
    return
  }
  let conn = self.connections[slot]
  conn.client = None
  match conn.actor {
    Some(actor) => actor.close()
    None => ()
  }
  conn.actor = None
  conn.cached_tools = []
  conn.epoch = conn.epoch + 1
  let routes : Map[String, Int] = Map::from_array([])
  for i, live in self.connections {
    if live.client is None {
      continue
    }
    for tool in live.cached_tools {
      routes[tool.name.to_string()] = i
    }
  }
  self.tool_to_conn = routes
}

///|
/// Manages multiple MCP server connections with namespaced tool routing.
///
/// Servers come either from explicit `connect` calls or from self-governed
/// mcp.json discovery (`discover`); discovered servers activate through
/// `attach` + `activate` in the mode chosen at discovery time. Hosts that
/// must not block composition call `attach` + `start_probes` instead: every
/// pending server connects in a parallel background probe, and the Lazy
/// `on_start` activation remains the fallback for hosts that never call it.
pub(all) struct MCPToolBridge {
  mut connections : Array[MCPServerConn]
  mut tool_to_conn : Map[String, Int]
  /// Activation posture chosen at discovery time; never changes after.
  mode : LoadMode
  /// Discovered-but-not-yet-connected server configs (mcp.json path).
  pending : Array[MCPServerConfig]
  /// Host-provided long-lived task group. Every connection creation —
  /// connect, reconnect, or probe — must hold one (stdio spawns its child
  /// process on it). `None` until `attach`.
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
/// Discover servers from mcp.json (`<cwd>/.mcp.json` overriding the
/// user-level file at `user_mcp_json~` — the host owns that location) and
/// return a bridge ready to `attach` + `activate`. A malformed file fails
/// loud here — before any connection is attempted — with a sanitized
/// message.
pub async fn MCPToolBridge::discover(
  cwd~ : String,
  user_mcp_json~ : String,
  mode? : LoadMode = LoadMode::Eager,
) -> Result[MCPToolBridge, String] noraise {
  match discover_mcp_servers(cwd, user_mcp_json) {
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
/// Startup-probe retry schedule: after the first failure a probe retries up
/// to 3 times, sleeping between attempts (tests may inject a shorter
/// schedule through `start_probes`' optional parameter).
let probe_retry_backoff_ms : Array[Int] = [3_000, 15_000, 60_000]

///|
/// Composition-time probe entry: claim every discovered server and connect
/// each one in a parallel background probe on the attached task group,
/// returning before any handshake settles. A success bumps the catalog
/// revision and the live connection stays up (keep-alive) for later
/// executes. A failed probe is transient: it retries in the background on
/// the same task, and a retry success scrubs that server's entries from
/// `failures()` so `/mcp` reflects the recovery; exhausting the schedule
/// leaves exactly one final failure entry. A probe's retries never affect
/// the other servers. Flipping `activated` neutralizes the Lazy `on_start`
/// hook, which stays the activation path for hosts that never call this.
pub fn MCPToolBridge::start_probes(
  self : MCPToolBridge,
  backoff_ms? : Array[Int] = probe_retry_backoff_ms,
) -> Unit {
  let claimed : Array[MCPServerConfig] = []
  for config in self.pending {
    claimed.push(config)
  }
  self.pending.clear()
  self.activated = true
  match self.group {
    Some(group) =>
      for config in claimed {
        group.spawn_bg(() => {
          // The duplicate-name guard in connect_with_group keeps a probe
          // from double-connecting against any concurrent explicit connect.
          match self.connect_with_group(config, group) {
            Ok(_) => self.catalog_revision = self.catalog_revision + 1
            Err(message) =>
              self.retry_startup_probe(config, message, backoff_ms)
          }
        })
      }
    None =>
      for config in claimed {
        let reason = "MCP probe skipped for '\{@devkit.sanitize_label(config.name)}': bridge not attached to a task group"
        self.startup_failures.push((config.name, reason))
      }
  }
}

///|
/// Bounded background retry for one failed startup probe (`start_probes`
/// only; `activate` is unchanged). Every failed attempt records its entry;
/// a retry success bumps the catalog revision and scrubs this server's
/// entries; exhausting the schedule leaves exactly one final entry.
async fn MCPToolBridge::retry_startup_probe(
  self : MCPToolBridge,
  config : MCPServerConfig,
  first_message : String,
  backoff_ms : Array[Int],
) -> Unit {
  let mut last_message = first_message
  self.startup_failures.push((config.name, last_message))
  for backoff in backoff_ms {
    @async.sleep(backoff)
    match self.group {
      Some(group) =>
        match self.connect_with_group(config, group) {
          Ok(_) => {
            self.catalog_revision = self.catalog_revision + 1
            self.scrub_startup_failures(config.name)
            return
          }
          Err(message) => {
            last_message = message
            self.startup_failures.push((config.name, message))
          }
        }
      None => {
        last_message = missing_task_group_message(config.name)
        self.startup_failures.push((config.name, last_message))
      }
    }
  }
  self.scrub_startup_failures(config.name)
  self.startup_failures.push((config.name, last_message))
}

///|
/// Drop every failure entry recorded for one server name (recovery scrub).
fn MCPToolBridge::scrub_startup_failures(
  self : MCPToolBridge,
  name : String,
) -> Unit {
  let kept : Array[(String, String)] = []
  for pair in self.startup_failures {
    if pair.0 != name {
      kept.push(pair)
    }
  }
  self.startup_failures.clear()
  for pair in kept {
    self.startup_failures.push(pair)
  }
}

///|
/// Connect every discovered server, blocking until each connect settles.
/// Per-server failures are returned (and recorded) instead of raised: a down
/// server degrades to "its tools are absent from the catalog", it never
/// aborts the host. Eager hosts call this right after `attach`; hosts that
/// must not block composition call `start_probes` instead. In Lazy mode the
/// bridge activates itself in `Lifecycle::on_start` (before the first turn's
/// catalog read) — that fallback stays armed unless `start_probes` already
/// claimed the pending servers.
pub async fn MCPToolBridge::activate(
  self : MCPToolBridge,
) -> Array[(String, String)] {
  self.activated = true
  for config in self.pending {
    match self.group {
      Some(group) =>
        match self.connect_with_group(config, group) {
          Ok(_) => ()
          Err(message) => self.startup_failures.push((config.name, message))
        }
      None =>
        self.startup_failures.push(
          (config.name, missing_task_group_message(config.name)),
        )
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
  match self.connect_with_group(config, group) {
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
/// raw connect error before it is discarded. The group contract requires a
/// task group for every connection creation — the no-group guard lives with
/// the callers.
async fn MCPToolBridge::open_client(
  self : MCPToolBridge,
  config : MCPServerConfig,
  group : @async.TaskGroup[Unit],
) -> Result[@client.MCPClient, String] {
  match config.transport {
    @transport.AnyTransport::StdioClient(t) => {
      let (cmd, args, extra_env) = stdio_cmd(t)
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
/// Core connect: the caller must hold a task group — stdio spawns its child
/// process on it, and under the group contract no connection creation
/// proceeds without one. A retired slot for the same server name is refilled
/// in place instead of appending a second slot, so slot indexes stay stable
/// for the lifetime of the bridge.
async fn MCPToolBridge::connect_with_group(
  self : MCPToolBridge,
  config : MCPServerConfig,
  group : @async.TaskGroup[Unit],
) -> Result[Unit, String] {
  let mut refill_slot = -1
  let mut refill_epoch = 0
  for i, conn in self.connections {
    if conn.name == config.name {
      if conn.client is Some(_) {
        return Err(
          "MCP connection name already exists: '\{@devkit.sanitize_label(config.name)}'",
        )
      }
      refill_slot = i
      refill_epoch = conn.epoch
      break
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
  let idx = if refill_slot >= 0 {
    refill_slot
  } else {
    self.connections.length()
  }
  match
    self.commit_connection(
      config,
      client,
      tools,
      idx,
      group~,
      expect_epoch=refill_epoch,
    ) {
    Ok(_) => Ok(())
    Err(message) => {
      client.close()
      Err(message)
    }
  }
}

///|
/// Shared "validate + commit" tail of every fresh-connect path (explicit
/// connect, probe, and the retire-then-refill of `reconnect_server`).
/// Validates the candidate catalog for slot `idx` against the other slots
/// (retired slots contribute their empty tool lists); only after validation
/// stores the client, spawns the connection actor on `group`, writes the
/// connection in place (appending when `idx` is one past the end), swaps the
/// routing map, and registers the config. An in-place refill must land on
/// the slot incarnation the caller observed (`expect_epoch`): a concurrent
/// retire+refill of the same slot changed the epoch, and this candidate
/// loses — the caller closes `client` — instead of clobbering the winner's
/// connection and actor. No live state is touched on a failed validation.
fn MCPToolBridge::commit_connection(
  self : MCPToolBridge,
  config : MCPServerConfig,
  client : @client.MCPClient,
  tools : Array[@posoco.ToolDef],
  idx : Int,
  group~ : @async.TaskGroup[Unit],
  expect_epoch~ : Int,
) -> Result[Unit, String] {
  // The slot may have vanished while the caller was suspended (e.g. close()
  // cleared the registry): fail honestly instead of writing a shifted index.
  if idx > self.connections.length() {
    return Err("MCP connection is no longer present")
  }
  let appending = idx == self.connections.length()
  if !appending && self.connections[idx].epoch != expect_epoch {
    return Err("MCP connection is no longer present")
  }
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
    client: Some(client),
    actor: Some(ConnActor::start(group~, client~)),
    cached_tools: tools,
    config,
    epoch: expect_epoch,
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
/// Commit an in-place refill for a reconnect runner that already owns the
/// slot's actor: validates the candidate catalog against the other slots,
/// then — only on the slot incarnation the runner observed — installs the
/// fresh client mirror and the tool list. The actor itself is not replaced
/// (its fold receives the client through EndReconnect), so a matching epoch
/// implies the slot still holds exactly the actor that granted the
/// reconnect. A concurrent retire+refill changed the epoch; this candidate
/// loses and the caller closes `client`. The slot's config is untouched —
/// the runner reconnects from it, and `configs[name]` is only ever written
/// together with the slot it belongs to.
fn MCPToolBridge::commit_reconnect_fill(
  self : MCPToolBridge,
  client : @client.MCPClient,
  tools : Array[@posoco.ToolDef],
  idx : Int,
  expect_epoch~ : Int,
) -> Result[Unit, String] {
  if idx >= self.connections.length() {
    return Err("MCP connection is no longer present")
  }
  let conn = self.connections[idx]
  if conn.epoch != expect_epoch {
    return Err("MCP connection is no longer present")
  }
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
  let plan = match plan_catalog(catalog_entries, self.connections.length()) {
    Ok(plan) => plan
    Err(message) => return Err(message)
  }
  conn.client = Some(client)
  conn.cached_tools = tools
  self.commit_catalog(plan)
  Ok(())
}

///|
/// One `tools/list` fetch under an already-granted admission. The EndCall
/// pairing is deferred across every exit (cancellation included — an
/// unobservable outcome returns its admission as TransportFail); a TimedOut
/// fetch additionally stigmatizes exactly its own generation, so a stale
/// tools/list reply cannot be re-delivered to the next refresh either.
async fn MCPToolBridge::fetch_admitted(
  self : MCPToolBridge,
  actor : ConnActor[@client.MCPClient],
  permit : ConnPermit[@client.MCPClient],
  server : String,
  timeout_ms : Int,
) -> Result[Array[@posoco.ToolDef], String] {
  let mut outcome : CallOutcome = CallOutcome::TransportFail
  defer {
    let _ = actor.end_call(generation=permit.generation, outcome~)
  }
  match
    self.fetch_tools(server, permit.client, timeout_ms, record_challenges=false) {
    Ok(tools) => {
      outcome = CallOutcome::CallOk
      Ok(tools)
    }
    Err(failure) => {
      outcome = match failure {
        ListToolsFailure::TimedOut(_) => CallOutcome::TimedOut
        ListToolsFailure::Failed => CallOutcome::TransportFail
      }
      Err(
        list_tools_failure_message(
          "MCP refresh list_tools failed", server, failure,
        ),
      )
    }
  }
}

///|
/// Refresh-side fetch for one live slot: acquire → fetch under the deferred
/// EndCall pairing; a NeedsReconnect generation (Denied(ReconnectFirst))
/// forces one reconnect through the runner and one re-acquire — the
/// stale-response safety of the call path, applied to tools/list. Every
/// other denial or fetch failure is this slot's error; refresh never
/// reactively retries a failed fetch (unchanged).
async fn MCPToolBridge::refresh_fetch_one(
  self : MCPToolBridge,
  conn_idx : Int,
  actor : ConnActor[@client.MCPClient],
  server : String,
  timeout_ms : Int,
) -> Result[Array[@posoco.ToolDef], String] {
  let admission_failed = list_tools_failure_message(
    "MCP refresh list_tools failed",
    server,
    ListToolsFailure::Failed,
  )
  // (permit, deadline it was admitted under): a forced reconnect re-reads
  // the deadline from the slot after the await — the config may have been
  // replaced by a concurrent refill.
  let admitted : (ConnPermit[@client.MCPClient], Int) = match
    conn_actor_acquire(actor, conn_ask_timeout(timeout_ms)) {
    Err(_) => return Err(admission_failed)
    Ok(Permit(permit)) => (permit, timeout_ms)
    Ok(Denied(ReconnectFirst)) =>
      match self.reconnect_one(conn_idx) {
        Err(_) => return Err(admission_failed)
        Ok(_) =>
          match self.live_slot_for(conn_idx, server) {
            Some(current) =>
              match
                conn_actor_acquire(
                  actor,
                  conn_ask_timeout(current.config.timeout_ms),
                ) {
                Err(_) => return Err(admission_failed)
                Ok(Permit(permit)) => (permit, current.config.timeout_ms)
                Ok(_) => return Err(admission_failed)
              }
            None => return Err(admission_failed)
          }
      }
    Ok(_) => return Err(admission_failed)
  }
  let (permit, admitted_timeout) = admitted
  self.fetch_admitted(actor, permit, server, admitted_timeout)
}

///|
/// Refresh cached tools from all connected MCP servers.
pub async fn MCPToolBridge::refresh_tools(
  self : MCPToolBridge,
) -> Result[Unit, String] {
  let fetches : Array[Result[CatalogEntry, String]] = []
  for i, conn in self.connections {
    // A retired slot is an absent server: contribute an empty entry (the
    // catalog plan requires one entry per slot) and never touch the wire.
    if conn.client is None {
      fetches.push(Ok(CatalogEntry::{ connection_index: i, tools: [], }))
      continue
    }
    let actor = match conn.actor {
      Some(actor) => actor
      None => {
        fetches.push(Ok(CatalogEntry::{ connection_index: i, tools: [], }))
        continue
      }
    }
    match self.refresh_fetch_one(i, actor, conn.name, conn.config.timeout_ms) {
      Ok(tools) =>
        fetches.push(Ok(CatalogEntry::{ connection_index: i, tools, }))
      Err(message) => {
        // The slot may have been retired while this task was suspended (a
        // concurrent reconnect_server): an absent server contributes an
        // empty entry exactly like a slot that was already retired at loop
        // entry. Any other failure ends the refresh with the error.
        let vanished = if i >= self.connections.length() {
          true
        } else {
          let current = self.connections[i]
          current.client is None || current.name != conn.name
        }
        if vanished {
          fetches.push(Ok(CatalogEntry::{ connection_index: i, tools: [], }))
        } else {
          fetches.push(Err(message))
          break
        }
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
/// Close all MCP connections and clear state. Each slot's client closes
/// inline, its actor mailbox closes with it, and the loop is JOINED before
/// this returns — the graceful-drain confirmation (fuwaroid: `close`
/// requests the stop, `join` watches the loop task terminate, so
/// `close(); join()` completed means every EndCall/EndReconnect already
/// queued folded in FIFO order). Tells issued after the drain are refused
/// with `MailboxClosed`, which the call path already maps to an honest
/// transport failure. `join` raises exactly when THIS caller is being
/// cancelled — host cancellation outranks draining, so that identity
/// propagates untouched instead of being swallowed into a normal return
/// (`on_shutdown` shields the drain from that with `protect_from_cancel`).
/// `Cancelled` means the host cancelled the loop; `Failed(error)` means
/// it ended abnormally on its own. In the failed case the original error was
/// already re-raised into the host group's fail-fast when the loop task
/// terminated, so teardown proceeds with nothing retried and nothing masked. Async since mcp 0.15: the
/// underlying client close performs I/O and cannot block the caller.
pub async fn MCPToolBridge::close(self : MCPToolBridge) -> Unit {
  for conn in self.connections {
    match conn.client {
      Some(client) => client.close()
      None => ()
    }
    match conn.actor {
      Some(actor) => {
        actor.close()
        match actor.join() {
          Graceful => ()
          Cancelled => ()
          Failed(_cause) => ()
        }
      }
      None => ()
    }
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
/// old connection is retired in place — client closed fire-and-forget,
/// actor closed, cached tools dropped, routing replayed from the live
/// slots — so no index ever shifts under an in-flight call. A failed
/// re-connect leaves the slot retired, which degrades to "this server's
/// tools are absent from the catalog" instead of a stale client; a
/// successful one refills the same slot through `commit_connection` with a
/// fresh actor.
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
  // Precondition before any destructive work: the refill cannot even be
  // attempted without a group, so the live connection is left untouched.
  let group = match self.group {
    Some(group) => group
    None => return Err(missing_task_group_message(server))
  }
  let mut slot = -1
  for i, conn in self.connections {
    if conn.name == server {
      slot = i
      break
    }
  }
  if slot >= 0 {
    // Retire first: the old client closes fire-and-forget on the group and
    // the slot's actor closes with it, so a reconnect runner that still
    // holds that actor loses structurally (its BeginReconnect/EndReconnect
    // hit a closed mailbox) and cannot clobber this refill.
    match self.connections[slot].client {
      Some(client) =>
        group.spawn_bg(() => {
          let _ = client.close() catch { _ => () }
        })
      None => ()
    }
    self.retire_slot(slot)
  }
  match self.connect_with_group(config, group) {
    Ok(_) => {
      self.catalog_revision = self.catalog_revision + 1
      Ok(())
    }
    Err(message) => Err(message)
  }
}

///|
/// One reconnect as an IO runner over the connection actor. BeginReconnect
/// grants exactly one winner per connection — a Busy loser fails with the
/// old "already in progress" text, and a slot retired meanwhile (its actor
/// closed) fails the ask honestly, so the double-connection race between
/// concurrent reconnects on one slot is decided by the actor, not by
/// check-then-act flags. The winner closes the previous-generation client
/// (only while the slot still holds the incarnation it observed — a racing
/// retire+refill replaced the lineage, and its fresh client must not be
/// closed by this loser), redoes the connect handshake and tool fetch in
/// this caller's task, and commits the refill in place before handing the
/// fresh client to the actor's fold. A failed or cancelled attempt folds
/// back to Fresh on the old (closed) client, so later calls fail fast
/// instead of hanging — the deferred EndReconnect guarantees the
/// Reconnecting fold is always exited, cancellation unwinding included, and
/// its duplicate after a normal completion is a structural no-op.
async fn MCPToolBridge::reconnect_one(
  self : MCPToolBridge,
  conn_idx : Int,
) -> Result[Unit, String] {
  if conn_idx >= self.connections.length() {
    return Err("MCP connection is no longer present")
  }
  let conn = self.connections[conn_idx]
  let server = conn.name
  // Precondition before any destructive work: without a group the reconnect
  // cannot proceed, so the slot (and its live client) is left untouched.
  let group = match self.group {
    Some(group) => group
    None => return Err(missing_task_group_message(server))
  }
  let actor = match conn.actor {
    Some(actor) => actor
    // A retired slot has no actor to arbitrate the refill; its refill
    // belongs to the path that retired it (e.g. reconnect_server's connect).
    None => return Err("MCP connection is no longer present")
  }
  let config = conn.config
  let epoch = conn.epoch
  let reply : Result[ConnReply[@client.MCPClient], @fuwaroid.AskFailure] = actor.begin_reconnect(
    timeout_ms=conn_ask_timeout(config.timeout_ms),
  ) catch {
    error => {
      // Host cancellation propagates untouched; anything else (closed or
      // stalled loop) is an honest admission failure of this reconnect.
      if @async.is_being_cancelled() {
        raise error
      }
      return Err(
        "MCP reconnect failed for '\{@devkit.sanitize_label(server)}' (stage=admission)",
      )
    }
  }
  let generation = match reply {
    Ok(Granted(generation=g)) => g
    Ok(Busy) =>
      return Err(
        "MCP reconnect already in progress for '\{@devkit.sanitize_label(server)}'",
      )
    _ =>
      return Err(
        "MCP reconnect failed for '\{@devkit.sanitize_label(server)}' (stage=admission)",
      )
  }
  // Compensating report on every non-normal exit (failed IO, validation
  // loss, cancellation): ok=false folds back to Fresh on the old client.
  defer {
    let _ = actor.end_reconnect(generation~, ok=false, client=None)
  }
  // The slot's lineage may have moved on while the grant was processed (a
  // racing retire bumped the epoch): lose fast — no client is opened for a
  // doomed refill, and a successor's fresh client is never closed here.
  if conn_idx >= self.connections.length() ||
    self.connections[conn_idx].epoch != epoch {
    return Err("MCP connection is no longer present")
  }
  match self.connections[conn_idx].client {
    Some(old) => old.close()
    None => ()
  }
  let client = match self.open_client(config, group) {
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
  match
    self.commit_reconnect_fill(client, tools, conn_idx, expect_epoch=epoch) {
    Ok(_) => {
      let _ = actor.end_reconnect(generation~, ok=true, client=Some(client))
      Ok(())
    }
    Err(message) => {
      client.close()
      Err(message)
    }
  }
}

///|
/// ToolProvider: return cached tools from all connected servers.
/// Tools are fetched during connect() and refresh_tools(). A retired slot
/// is an absent server: it advertises nothing.
pub impl @posoco.ToolProvider for MCPToolBridge with fn list_tools(self) -> Array[
  @posoco.ToolDef,
] {
  let all : Array[@posoco.ToolDef] = []
  for conn in self.connections {
    if conn.client is None {
      continue
    }
    for t in conn.cached_tools {
      all.push(t)
    }
  }
  all
}

///|
pub extend MCPToolBridge with @posoco.ToolProvider::{execute, list_tools}

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
  // Honest routing read: the route may point at a retired slot (the server
  // is absent after `reconnect_server` failed its refill) or at a registry
  // cleared by `close()`. Both fail here instead of indexing a shifted
  // array.
  let conn = match self.live_slot(conn_idx) {
    Some(conn) => conn
    None =>
      raise @posoco.RuntimeError::InvocationFailed(
        "MCP connection is no longer present (tool='\{@devkit.sanitize_label(call_name)}')",
      )
  }
  let invoked_server = conn.name
  let original_name = strip_namespace(call_name, invoked_server)
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
    Err(failure) =>
      // The timeout stigma is already folded inside the actor by the failed
      // attempt's deferred EndCall — stamped on its own generation, so a
      // successor connection is never marked NeedsReconnect by a stale
      // report. Only the typed failure surfaces here.
      raise mcp_call_failure(failure, original_name)
  }
  let raw = convert_content_to_string(result.content)
  let (content, truncated) = mcp_model_text(
    raw,
    if result.is_error {
      MCP_ERROR_OUTPUT_CHARS
    } else {
      MCP_SUCCESS_OUTPUT_CHARS
    },
  )
  let structured = mcp_outcome_structured(truncated)
  if result.is_error {
    @posoco.ToolOutcome::ToolReportedError(content~, structured~)
  } else {
    @posoco.ToolOutcome::Success(content~, structured~)
  }
}

///|
/// The ask deadline for actor arbitration: the connection's own `timeout_ms`
/// when one is configured, else a large constant (0 means "no deadline", so
/// the admission ask must not use it literally).
fn conn_ask_timeout(timeout_ms : Int) -> Int {
  if timeout_ms > 0 {
    timeout_ms
  } else {
    60_000
  }
}

///|
/// Acquire one call admission through the connection actor, mapping ask
/// failures the way the call path demands: host cancellation of the caller
/// is re-raised untouched (never swallowed into a failure value), while a
/// closed, stopped, or stalled loop is an honest transport-level failure of
/// THIS call — the actor mailbox refuses after retire/close, and the caller
/// already maps that to `stage=transport`.
async fn conn_actor_acquire(
  actor : ConnActor[@client.MCPClient],
  timeout_ms : Int,
) -> Result[ConnReply[@client.MCPClient], MCPCallFailure] {
  let reply : Result[ConnReply[@client.MCPClient], @fuwaroid.AskFailure] = actor.acquire(
    timeout_ms~,
  ) catch {
    error => {
      if @async.is_being_cancelled() {
        raise error
      }
      return Err(MCPCallFailure::TransportFailure)
    }
  }
  match reply {
    Err(_) => Err(MCPCallFailure::TransportFailure)
    Ok(answer) => Ok(answer)
  }
}

///|
/// One `tools/call` attempt under an actor admission. The EndCall pairing
/// is deferred so it fires on every exit — normal, failure, and
/// cancellation unwinding: an outcome that cannot be observed (the
/// cancellation raced the attempt) returns its admission as TransportFail,
/// so in_flight never leaks. The defer closure captures the outcome cell by
/// reference, so the report always carries the latest fold; a TimedOut
/// outcome additionally stigmatizes exactly its own generation inside the
/// actor (stale-response safety), never a successor's.
async fn call_under_permit(
  actor : ConnActor[@client.MCPClient],
  permit : ConnPermit[@client.MCPClient],
  timeout_ms : Int,
  tool_name : String,
  args_str : String,
) -> Result[@client.CallToolResult, MCPCallFailure] {
  let mut outcome : CallOutcome = CallOutcome::TransportFail
  defer {
    let _ = actor.end_call(generation=permit.generation, outcome~)
  }
  match call_tool_attempt(permit.client, timeout_ms, tool_name, args_str) {
    Ok(result) => {
      outcome = CallOutcome::CallOk
      Ok(result)
    }
    Err(failure) => {
      outcome = match failure {
        MCPCallFailure::TransportFailure => CallOutcome::TransportFail
        MCPCallFailure::RemoteFailure => CallOutcome::RemoteFail
        MCPCallFailure::TimedOut(_) => CallOutcome::TimedOut
      }
      Err(failure)
    }
  }
}

///|
/// One logical MCP tool invocation: an actor-admitted `tools/call` attempt,
/// plus at most one reactive reconnect-and-retry. A generation marked
/// NeedsReconnect (Denied(ReconnectFirst)) is force-reconnected before
/// reuse, whatever `max_reconnects` says — reusing it could hand a stale
/// response to this call; a Busy or failed forced reconnect surfaces this
/// call as a transport failure, the same outcome the old flag discipline
/// produced by calling on the closed client. Connection-level failures and
/// timeouts are reconnect-eligible when `max_reconnects > 0` (a Busy or
/// failed reconnect surfaces the original failure); server JSON-RPC errors
/// never are. Every slot read after an await is re-validated against the
/// server this call started on.
async fn MCPToolBridge::invoke_mcp_tool(
  self : MCPToolBridge,
  conn_idx : Int,
  tool_name : String,
  args_str : String,
) -> Result[@client.CallToolResult, MCPCallFailure] {
  // Capture the slot identity this call belongs to before any await: the
  // registry may retire, refill, or clear the slot while this task is
  // suspended. A live slot always holds its actor alongside the client
  // mirror (both are written only in the commit/retire seams).
  let conn = match self.live_slot(conn_idx) {
    Some(conn) => conn
    None => return Err(MCPCallFailure::TransportFailure)
  }
  let invoked_server = conn.name
  let actor = match conn.actor {
    Some(actor) => actor
    None => return Err(MCPCallFailure::TransportFailure)
  }
  let timeout_ms = conn.config.timeout_ms
  let ask_ms = conn_ask_timeout(timeout_ms)
  let first : Result[@client.CallToolResult, MCPCallFailure] = match
    conn_actor_acquire(actor, ask_ms) {
    Err(failure) => return Err(failure)
    Ok(Permit(permit)) =>
      call_under_permit(actor, permit, timeout_ms, tool_name, args_str)
    Ok(Denied(ReconnectFirst)) =>
      match self.reconnect_one(conn_idx) {
        Err(_) => return Err(MCPCallFailure::TransportFailure)
        Ok(_) =>
          match conn_actor_acquire(actor, ask_ms) {
            Err(failure) => return Err(failure)
            Ok(Permit(permit)) =>
              call_under_permit(actor, permit, timeout_ms, tool_name, args_str)
            Ok(_) => return Err(MCPCallFailure::TransportFailure)
          }
      }
    Ok(Denied(ReconnectInProgress)) =>
      return Err(MCPCallFailure::TransportFailure)
    Ok(_) => return Err(MCPCallFailure::TransportFailure)
  }
  match first {
    Ok(result) => Ok(result)
    Err(failure) => {
      let eligible = match failure {
        MCPCallFailure::RemoteFailure => false
        MCPCallFailure::TransportFailure | MCPCallFailure::TimedOut(_) => true
      }
      if !eligible {
        return Err(failure)
      }
      // The retry budget is read post-await from the slot this call started
      // on — the config may have been replaced by a concurrent refill.
      let retryable = match self.live_slot_for(conn_idx, invoked_server) {
        Some(current) => current.config.max_reconnects > 0
        None => false
      }
      if !retryable {
        return Err(failure)
      }
      // At most one reactive reconnect-and-retry. The TimedOut stigma of
      // the failed attempt is already folded by its deferred EndCall; the
      // runner closes the slot's current-generation client and hands the
      // fresh one to the actor's fold before this re-acquire.
      match self.reconnect_one(conn_idx) {
        Err(_) => Err(failure)
        Ok(_) =>
          match conn_actor_acquire(actor, ask_ms) {
            Err(_) => Err(failure)
            Ok(Permit(permit)) =>
              call_under_permit(actor, permit, timeout_ms, tool_name, args_str)
            Ok(_) => Err(failure)
          }
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
pub extend MCPToolBridge with @posoco.Lifecycle::{on_compose}

///|
/// The async slot accepts this impl: the body's async close call is inferred.
/// The drain runs inside a cancellation-protected region — a host
/// cancellation landing mid-shutdown must not truncate the actor joins
/// (core keeps its own shutdown under the same protection), and the
/// Lifecycle contract propagates a cleanup failure loudly. The task stays
/// in the cancelled state afterwards, so the host's teardown continues
/// unimpeded once close returns.
pub impl @posoco.Lifecycle for MCPToolBridge with fn on_shutdown(self) -> Unit {
  let _ = @async.protect_from_cancel(() => self.close())
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
  @posoco.ExtensionManifest(
    id="posoco_ext_mcp",
    tools=[self],
    lifecycle=[self],
    commands=[self],
  )
}

///|
pub extend MCPToolBridge with @posoco.Extension::{extension_id, manifest}

///|
pub extend MCPToolBridge with @posoco.Lifecycle::{on_start, on_shutdown}
