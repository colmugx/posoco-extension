///|
/// Result of one MCP tool call. `is_error` is the server's own error flag;
/// `text` joins the text content items — the Nowledge Mem server returns its
/// `--json` payloads as text content, so the extension's existing payload
/// parsers (acks/context/wm) keep working unchanged.
pub(all) struct McpCallOutcome {
  is_error : Bool
  text : String
} derive(Debug)

///|
/// Narrow seam for the Nowledge Mem MCP connection.
pub(open) trait NmemMcp {
  /// Install the resolved endpoint. Called once from `on_start`; calls
  /// before `configure` fail with a clear message instead of guessing a
  /// server address.
  fn configure(Self, url~ : String, auth_token~ : String?, name~ : String) -> Unit
  async fn call_tool(Self, tool : String, args : Json, timeout_ms~ : Int) -> Result[
    McpCallOutcome,
    String,
  ]
  /// Connectivity probe: ensure the connection, `list_tools`, and report the
  /// server identity plus tool count (the `nmem_status` / `/memory status`
  /// surface).
  async fn probe(Self, timeout_ms~ : Int) -> Result[String, String]
  async fn shutdown(Self) -> Unit
}

///|
/// Production `NmemMcp`: one lazily-connected streamable-HTTP client over
/// `colmugx/mcp`. Connect on first use; a connection-level failure or
/// timeout drops the client so the next call reconnects (a server-side
/// JSON-RPC error is a genuine answer and keeps the connection). Cancellation
/// is never swallowed: a cancelled caller's error propagates unchanged.
pub(all) struct LazyNmemMcp {
  mut url : String?
  mut auth_token : String?
  mut client_name : String
  mut client : @client.MCPClient?
  mut connected_url : String?
}

///|
pub fn LazyNmemMcp::LazyNmemMcp() -> LazyNmemMcp {
  {
    url: None,
    auth_token: None,
    client_name: "nowledge-mem",
    client: None,
    connected_url: None,
  }
}

///|
pub impl NmemMcp for LazyNmemMcp with fn configure(
  self : LazyNmemMcp,
  url~ : String,
  auth_token~ : String?,
  name~ : String,
) -> Unit {
  self.url = Some(url)
  self.auth_token = auth_token
  self.client_name = name
}

///|
/// Connect if needed and return the live client. A `configure` with a
/// different endpoint retires the live connection first (the usual run is
/// one `configure` before any connection, so this only guards misuse).
async fn LazyNmemMcp::ensure_connected(
  self : LazyNmemMcp,
) -> Result[@client.MCPClient, String] {
  guard self.url is Some(url) else {
    return Err("nowledge-mem mcp client not configured (on_start not run)")
  }
  if self.client is Some(live) {
    if self.connected_url == Some(url) {
      return Ok(live)
    }
    live.close()
    self.client = None
    self.connected_url = None
  }
  // nmem-serv is a known 2025-11-25 legacy MCP server: its modern-era
  // discover probe is rejected with 422, so connect straight to the legacy
  // initialize and skip the probe (saves one doomed POST per connection).
  // MARK: if nmem-serv upgrades to the modern protocol, update `era=` here.
  let connect = async fn() {
    match self.auth_token {
      Some(token) =>
        @client.MCPClient::connect_http(
          url~,
          name=self.client_name,
          version="0.1.0",
          auth_token=token,
          era=@client.ProtocolEra::Legacy,
        )
      None =>
        @client.MCPClient::connect_http(
          url~,
          name=self.client_name,
          version="0.1.0",
          era=@client.ProtocolEra::Legacy,
        )
    }
  }
  let connected = connect() catch {
    err =>
      return Err("nowledge-mem mcp connect raised (\{url}): " + err.to_string())
  }
  let connected = match connected {
    Ok(client) => client
    Err(err) =>
      return Err("nowledge-mem mcp connect failed (\{url}): " + err.message())
  }
  // Concurrent first calls may both pass the None check; the loser closes so
  // exactly one client survives.
  match self.client {
    Some(existing) => {
      connected.close()
      Ok(existing)
    }
    None => {
      self.client = Some(connected)
      self.connected_url = Some(url)
      Ok(connected)
    }
  }
}

///|
async fn LazyNmemMcp::drop_connection(self : LazyNmemMcp) -> Unit {
  match self.client {
    Some(client) => {
      client.close()
      self.client = None
      self.connected_url = None
    }
    None => ()
  }
}

///|
/// Wire-level breaks a fresh connection can fix — the same classification
/// posoco-ext-mcp applies (SDK send/receive breaks arrive as wrapped
/// `TransportError` or `InternalError` with these prefixes; server
/// JSON-RPC errors are remote answers, not connection problems).
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
/// Join the text content items of a call result (non-text items are not
/// part of the Nowledge Mem surface and are skipped).
fn call_result_text(result : @client.CallToolResult) -> String {
  let parts : Array[String] = []
  for item in result.content {
    match item {
      @types.ContentItem::Text(text) => parts.push(text)
      _ => ()
    }
  }
  parts.join("\n")
}

///|
pub impl NmemMcp for LazyNmemMcp with fn call_tool(
  self : LazyNmemMcp,
  tool : String,
  args : Json,
  timeout_ms~ : Int,
) -> Result[McpCallOutcome, String] {
  @async.with_timeout(timeout_ms, () => {
    let connected = self.ensure_connected() catch {
      err => return Err("nowledge-mem mcp raised: " + err.to_string())
    }
    let client = match connected {
      Ok(client) => client
      Err(message) => return Err(message)
    }
    let result = client.call_tool(tool, arguments=args.stringify()) catch {
      err => {
        self.drop_connection()
        return Err("mcp call '\{tool}' raised: " + err.to_string())
      }
    }
    let result = match result {
      Ok(result) => result
      Err(err) => {
        if is_connection_level_error(err) {
          self.drop_connection()
        }
        return Err("mcp call '\{tool}' failed: " + err.message())
      }
    }
    Ok({ is_error: result.is_error, text: call_result_text(result), })
  }) catch {
    @async.TimeoutError => {
      self.drop_connection()
      Err("mcp call '\{tool}' timed out (timeout_ms=\{timeout_ms})")
    }
    err => {
      if @async.is_being_cancelled() {
        raise err
      }
      Err("nowledge-mem mcp call raised: " + err.to_string())
    }
  }
}

///|
pub impl NmemMcp for LazyNmemMcp with fn probe(
  self : LazyNmemMcp,
  timeout_ms~ : Int,
) -> Result[String, String] {
  @async.with_timeout(timeout_ms, () => {
    let connected = self.ensure_connected() catch {
      err => return Err("nowledge-mem mcp raised: " + err.to_string())
    }
    let client = match connected {
      Ok(client) => client
      Err(message) => return Err(message)
    }
    let listed = client.list_tools() catch {
      err => {
        self.drop_connection()
        return Err("nowledge-mem mcp list_tools raised: " + err.to_string())
      }
    }
    let listed = match listed {
      Ok(listed) => listed
      Err(err) => {
        if is_connection_level_error(err) {
          self.drop_connection()
        }
        return Err("nowledge-mem mcp list_tools failed: " + err.message())
      }
    }
    let identity = match client.server_info {
      Some(info) => "\{info.name} \{info.version}"
      None => "nowledge-mem"
    }
    Ok("\{identity}, \{listed.tools.length()} tools")
  }) catch {
    @async.TimeoutError => {
      self.drop_connection()
      Err("nowledge-mem mcp probe timed out (timeout_ms=\{timeout_ms})")
    }
    err => {
      if @async.is_being_cancelled() {
        raise err
      }
      Err("nowledge-mem mcp probe raised: " + err.to_string())
    }
  }
}

///|
pub impl NmemMcp for LazyNmemMcp with fn shutdown(self : LazyNmemMcp) -> Unit {
  self.drop_connection()
}

///|
pub extend LazyNmemMcp with NmemMcp::{configure, call_tool, probe, shutdown}
