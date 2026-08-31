///|
// Host-facing `mcp` command: makes the bridge's connection state visible —
// per-server tool counts, activation failure reasons, and not-yet-activated
// pending servers — so a down server is seen here instead of being silently
// absent from the tool catalog. The default action reads only cached state
// (zero IO); `refresh` re-lists tools from connected servers and bumps the
// catalog revision, so a wired McpCatalogSource re-reads at the next turn.

///|
priv enum McpRowState {
  Connected(Int)
  Failed(String)
  Pending
}

///|
priv struct McpStatusRow {
  name : String
  state : McpRowState
}

///|
fn MCPToolBridge::status_rows(self : MCPToolBridge) -> Array[McpStatusRow] {
  let rows : Array[McpStatusRow] = []
  for conn in self.connections {
    rows.push({ name: conn.name, state: Connected(conn.cached_tools.length()), })
  }
  for pair in self.startup_failures {
    let (name, reason) = pair
    rows.push({ name, state: Failed(reason), })
  }
  // Pending rows only make sense before the first activation: `activate`
  // never clears `pending`, so afterwards every declared server has either
  // a connection row or a failure row above.
  if !self.activated {
    for config in self.pending {
      rows.push({ name: config.name, state: Pending, })
    }
  }
  rows
}

///|
fn mcp_row_status_label(state : McpRowState) -> String {
  match state {
    Connected(_) => "connected"
    Failed(_) => "failed"
    Pending => "pending"
  }
}

///|
fn format_mcp_status(mode : LoadMode, rows : Array[McpStatusRow]) -> String {
  if rows.is_empty() {
    return "no MCP servers configured"
  }
  let mut connected = 0
  let mut failed = 0
  let mut pending = 0
  for row in rows {
    match row.state {
      Connected(_) => connected = connected + 1
      Failed(_) => failed = failed + 1
      Pending => pending = pending + 1
    }
  }
  let server_word = if rows.length() == 1 { "server" } else { "servers" }
  let lines : Array[String] = [
    "\{rows.length()} \{server_word}: \{connected} connected, \{failed} failed, \{pending} pending",
  ]
  for row in rows {
    let name = @devkit.sanitize_label(row.name)
    let line = match row.state {
      Connected(count) =>
        "- \{name}: connected, \{count} \{if count == 1 { "tool" } else { "tools" }}"
      Failed(reason) =>
        "- \{name}: failed — \{@devkit.sanitize_label(reason)}"
      Pending =>
        if mode is Lazy {
          "- \{name}: pending (connects on first turn)"
        } else {
          "- \{name}: pending"
        }
    }
    lines.push(line)
  }
  lines.join("\n")
}

///|
fn mcp_status_json(mode : LoadMode, rows : Array[McpStatusRow]) -> Json {
  let servers : Array[Json] = []
  for row in rows {
    let fields : Array[(String, Json)] = [
      ("name", Json::string(row.name)),
      ("status", Json::string(mcp_row_status_label(row.state))),
    ]
    match row.state {
      Connected(count) =>
        fields.push(("tools", Json::number(count.to_double())))
      Failed(reason) => fields.push(("reason", Json::string(reason)))
      Pending => ()
    }
    servers.push(Json::object(Map::from_array(fields)))
  }
  Json::object(
    Map::from_array([
      ("kind", Json::string("mcp_status")),
      ("mode", Json::string(if mode is Lazy { "lazy" } else { "eager" })),
      ("servers", Json::array(servers)),
    ]),
  )
}

///|
fn MCPToolBridge::command_status(
  self : MCPToolBridge,
) -> @posoco.CommandOutcome {
  let rows = self.status_rows()
  @posoco.CommandOutcome::Success(
    feedback=format_mcp_status(self.mode, rows),
    structured=Some(mcp_status_json(self.mode, rows)),
    ui_hint=Some(@posoco.UiHint::None),
  )
}

///|
async fn MCPToolBridge::command_refresh(
  self : MCPToolBridge,
) -> @posoco.CommandOutcome noraise {
  // refresh_tools may raise (async slot); fold that channel into the same
  // Err path as its Result so both surface as a command failure.
  let update : Result[Unit, String] = self.refresh_tools() catch {
    _ => Err("MCP refresh aborted unexpectedly")
  }
  match update {
    Ok(_) => {
      let rows = self.status_rows()
      @posoco.CommandOutcome::Success(
        feedback=format_mcp_status(self.mode, rows) +
          "\n(refreshed tool lists from connected servers)",
        structured=Some(mcp_status_json(self.mode, rows)),
        ui_hint=Some(@posoco.UiHint::None),
      )
    }
    Err(message) =>
      @posoco.CommandOutcome::Failure(
        reason="mcp refresh failed: \{@devkit.sanitize_label(message)}",
      )
  }
}

///|
pub impl @posoco.CommandPort for MCPToolBridge with fn commands(
  _self : MCPToolBridge,
) -> Array[@posoco.CommandDef] {
  [
    @posoco.CommandDef::{
      id: "mcp",
      label: "MCP Servers",
      description: "Show MCP server status and tool counts (action: refresh)",
      category: "mcp",
      ctype: @posoco.CommandType::Action,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
pub impl @posoco.CommandPort for MCPToolBridge with fn invoke(
  self : MCPToolBridge,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  if id != "mcp" {
    raise @posoco.CommandError::NotFound(id)
  }
  let action = match args {
    Json::Object(fields) =>
      match fields.get("action") {
        None => "list"
        Some(Json::String(value)) => value
        Some(_) =>
          raise @posoco.CommandError::InvalidArgs(
            reason="mcp: 'action' must be a string",
          )
      }
    Json::Null => "list"
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="mcp: arguments must be a JSON object",
      )
  }
  match action {
    "list" | "status" => self.command_status()
    "refresh" => self.command_refresh()
    other =>
      @posoco.CommandOutcome::Failure(
        reason="mcp: unknown action '\{@devkit.sanitize_label(other)}' (expected list or refresh)",
      )
  }
}

///|
pub extend MCPToolBridge with @posoco.CommandPort::{commands, invoke}
