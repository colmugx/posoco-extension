///|
/// Live-tool publication (posoco 0.23.1 dynamic tools). The bridge's live
/// MCP tools enter the kernel catalog as the bridge's OWN contribution
/// group — owner `posoco_ext_mcp`, fixed name→bridge bindings captured at
/// operation admission. This replaces the retired runtime-seam
/// `McpCatalogSource`: no host-owned layered catalog, no definition-only
/// snapshots.

///|
/// Host seam (mirror of the pi hidden-tools setter): names of statically
/// registered tools. A live MCP tool colliding with one is dropped from the
/// published group — base wins, exactly like the old layered shadowing —
/// instead of rejecting the whole group.
pub fn mcp_bridge_set_reserved_tools_json(
  bridge : MCPToolBridge,
  names_json : String,
) -> Unit {
  let parsed = @json.parse(names_json) catch {
    _ => {
      bridge.reserved_names = []
      return
    }
  }
  let names : Array[String] = []
  match parsed {
    Json::Array(items) =>
      for item in items {
        match item {
          Json::String(name) => names.push(name)
          _ => ()
        }
      }
    _ => ()
  }
  bridge.reserved_names = names
}

///|
/// One fixed snapshot of the publishable live tools. Definitions are read
/// once per publication and owned by the version; execution dispatches to
/// the bridge by name.
priv struct McpLiveTools {
  defs : Array[@kernel.ToolDef]
  bridge : MCPToolBridge
}

///|
impl @posoco.ToolProvider for McpLiveTools with fn list_tools(
  self : McpLiveTools,
) -> Array[@kernel.ToolDef] {
  self.defs.copy()
}

///|
impl @posoco.ToolProvider for McpLiveTools with fn execute(
  self : McpLiveTools,
  ctx : @posoco.ToolCallContext,
) -> @kernel.ToolOutcome raise @posoco.RuntimeError {
  @posoco.ToolProvider::execute(self.bridge, ctx)
}

///|
/// Bump the change signal and schedule a publication of the current live
/// tool set. Called from every site that used to bump `catalog_revision`:
/// activation attempts, successful (re)connects, and committed refreshes.
/// Publication is best-effort — a rejected group keeps the previous
/// snapshot and the failure is recorded, never raised: a down or duplicate
/// server must not kill the host turn.
fn MCPToolBridge::bump_catalog_revision(self : MCPToolBridge) -> Unit {
  self.catalog_revision = self.catalog_revision + 1
  match (self.group, self.contributions) {
    (Some(group), Some(_)) => group.spawn_bg(() => self.publish_live_tools())
    _ => ()
  }
}

///|
async fn MCPToolBridge::publish_live_tools(self : MCPToolBridge) -> Unit {
  let handle = match self.contributions {
    Some(handle) => handle
    None => return
  }
  let defs : Array[@kernel.ToolDef] = []
  for def in @posoco.ToolProvider::list_tools(self) {
    if !self.reserved_names.contains(def.name.to_string()) {
      defs.push(def)
    }
  }
  let names = defs.map(fn(def) { def.name.to_string() })
  if names == self.published_names {
    return
  }
  let provider = McpLiveTools::{ defs, bridge: self, } as &@posoco.ToolProvider
  let ack = handle.replace(provider~)
  match ack {
    Ok(_) => self.published_names = names
    Err(error) =>
      // Record without aborting the actor: the next successful refresh
      // re-publishes. Same failure ledger as activation problems.
      self.startup_failures.push(
        ("mcp-tools", "live tool publication rejected: " + error.to_string()),
      )
  }
}
