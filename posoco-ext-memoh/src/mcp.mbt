///|
/// Canonical display name currently emitted by Memoh for its Tool Gateway.
pub const MEMOH_TOOLS_MCP_NAME : String = "Memoh Tools"

///|
/// Provider-safe slug recognized by Memoh and used internally by Posoco's MCP
/// tool namespace. Normalizing to this slug avoids spaces in model-visible
/// names such as Memoh_Tools__memory_search.
pub const MEMOH_TOOLS_MCP_SLUG : String = "Memoh_Tools"

///|
/// Deadline for one gateway round trip. Memoh's catalog is not a set of fast
/// lookups: `ask_user` waits up to ten minutes for a human answer, `wait_until`
/// up to two, and `exec`/`browser_action`/`generate_*` routinely outlive a
/// default request deadline. The gateway is local and the call stays
/// cancellable (session/cancel unwinds it), so the deadline only has to sit
/// above Memoh's own ceiling instead of cutting a working call short.
const MEMOH_TOOLS_CALL_TIMEOUT_MS : Int32 = 660_000

///|
fn is_memoh_tools_name(name : String) -> Bool {
  let normalized = name.trim().to_owned().to_lower()
  normalized == "memoh tools" || normalized == "memoh_tools"
}

///|
/// Convert an ACP HTTP declaration for Memoh Tools into the Posoco MCP
/// configuration used by cetas-memoh.
///
/// Every non-empty header is forwarded in declaration order. Header values may
/// carry runtime/session credentials, so validation errors never include them.
/// The config uses NoAuth because Memoh supplies the complete host-scoped
/// request headers itself; the MCP transport must replay them verbatim.
fn memoh_http_mcp_config(
  server : @acp.McpServerHttp,
) -> @mcp.MCPServerConfig raise MemohError {
  if server.url.trim().is_empty() {
    raise InvalidMcpServer(reason="Memoh Tools HTTP url is empty")
  }
  let headers : Array[(String, String)] = []
  for header in server.headers {
    if header.name.trim().is_empty() {
      raise InvalidMcpServer(
        reason="Memoh Tools contains an empty HTTP header name",
      )
    }
    headers.push((header.name, header.value))
  }
  @mcp.MCPServerConfig::MCPServerConfig(
    name=MEMOH_TOOLS_MCP_SLUG,
    transport=@transport.AnyTransport::HttpClient(
      @transport.HttpClientTransport::HttpClientTransport(
        server.url,
        extra_headers=headers,
      ),
    ),
    auth=@mcp.ServerAuth::NoAuth,
    timeout_ms=MEMOH_TOOLS_CALL_TIMEOUT_MS,
  )
}

///|
/// Locate the single Memoh Tool Gateway declaration supplied by session/new
/// and convert it into a Posoco MCP config.
///
/// Unrelated MCP declarations are intentionally ignored. Memoh already
/// federates native tools, connectors and external MCP sources through its Tool
/// Gateway, so a dedicated Memoh host must not independently connect arbitrary
/// ACP-declared servers and bypass platform policy.
///
/// Both "Memoh Tools" and "Memoh_Tools" are accepted case-insensitively because
/// Memoh publishes both display-name and slug forms as stable aliases.
pub fn memoh_tools_mcp_config(
  servers : @acp.ProtocolNullable[Array[@acp.McpServer]],
) -> @mcp.MCPServerConfig raise MemohError {
  let declarations : Array[@acp.McpServer] = match servers {
    @acp.ProtocolNullable::Value(values) => values
    @acp.ProtocolNullable::Null | @acp.ProtocolNullable::Omitted => []
  }
  let mut found : @acp.McpServer? = None
  for server in declarations {
    let name = match server {
      @acp.McpServer::Stdio(value) => value.name
      @acp.McpServer::Http(value) => value.name
      @acp.McpServer::Sse(value) => value.name
    }
    if is_memoh_tools_name(name) {
      if found is Some(_) {
        raise InvalidMcpServer(reason="multiple Memoh Tools declarations")
      }
      found = Some(server)
    }
  }
  match found {
    None => raise MissingToolGateway
    Some(@acp.McpServer::Http(server)) => memoh_http_mcp_config(server)
    Some(@acp.McpServer::Stdio(_)) =>
      raise UnsupportedMcpTransport(transport="stdio")
    Some(@acp.McpServer::Sse(_)) =>
      raise UnsupportedMcpTransport(transport="sse")
  }
}
