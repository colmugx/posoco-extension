///|
// Host-facing `mcp` command: makes the bridge's connection state visible —
// per-server tool counts, the connection actor's folded health/generation/
// in-flight domain, activation failure reasons, and not-yet-activated
// pending servers — so a down server is seen here instead of being silently
// absent from the tool catalog. The default action reads only folded state
// (zero wire IO; the actor asks are pure folds); `refresh` re-lists tools
// from connected servers and bumps the catalog revision, so a wired
// McpCatalogSource re-reads at the next turn.

///|
/// Per-connection observability domain for one live slot: the actor's
/// folded view (health, generation, in_flight) plus the mailbox counter
/// triple selected for display (accepted/processed/abandoned — the
/// conservation law closes as `accepted - processed - abandoned ==
/// outstanding`, so the three are shown together or not at all).
priv struct McpConnStats {
  tools : Int
  health : ConnHealth
  generation : Int
  in_flight : Int
  accepted : Int64
  processed : Int64
  abandoned : Int64
}

///|
priv enum McpRowState {
  Connected(McpConnStats)
  Retired
  Failed(String)
  Pending
}

///|
priv struct McpStatusRow {
  name : String
  state : McpRowState
}

///|
fn mcp_health_label(health : ConnHealth) -> String {
  match health {
    Fresh => "fresh"
    NeedsReconnect => "needs-reconnect"
    Reconnecting => "reconnecting"
  }
}

///|
/// One live slot's row state from its actor: the folded view via the
/// Inspect ask plus the synchronous mailbox counters. Any ask failure (the
/// mailbox already closed — a retire in progress or a manual actor close —
/// a stalled loop, or a cancelled command context) degrades to `None`: the
/// slot displays as retired instead of raising out of the command seam, and
/// the sticky cancel flag survives so an aborted turn still aborts.
async fn mcp_conn_stats(
  actor : ConnActor[@client.MCPClient],
  tools : Int,
  timeout_ms : Int,
) -> McpConnStats? noraise {
  let probed : Result[ConnReply[@client.MCPClient], @fuwaroid.AskFailure] = actor.inspect(
    timeout_ms=conn_ask_timeout(timeout_ms),
  ) catch {
    _ => return None
  }
  match probed {
    Ok(View(view)) => {
      let counters = actor.snapshot()
      Some({
        tools,
        health: view.health,
        generation: view.generation,
        in_flight: view.in_flight,
        accepted: counters.accepted,
        processed: counters.processed,
        abandoned: counters.abandoned,
      })
    }
    _ => None
  }
}

///|
async fn MCPToolBridge::status_rows(
  self : MCPToolBridge,
) -> Array[McpStatusRow] noraise {
  let rows : Array[McpStatusRow] = []
  for conn in self.connections {
    // A slot holds its actor exactly when it holds its client (both are
    // written only in the commit/retire seams); a slot missing either is an
    // absent server — retired, or a bridge that never attached — and
    // displays as retired, never "connected, 0 tools".
    let stats = match conn.actor {
      Some(actor) =>
        if conn.client is Some(_) {
          mcp_conn_stats(
            actor,
            conn.cached_tools.length(),
            conn.config.timeout_ms,
          )
        } else {
          None
        }
      None => None
    }
    match stats {
      Some(stats) => rows.push({ name: conn.name, state: Connected(stats), })
      None => rows.push({ name: conn.name, state: Retired, })
    }
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
    Retired => "retired"
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
  let mut retired = 0
  let mut failed = 0
  let mut pending = 0
  for row in rows {
    match row.state {
      Connected(_) => connected = connected + 1
      Retired => retired = retired + 1
      Failed(_) => failed = failed + 1
      Pending => pending = pending + 1
    }
  }
  let server_word = if rows.length() == 1 { "server" } else { "servers" }
  let lines : Array[String] = [
    "\{rows.length()} \{server_word}: \{connected} connected, \{retired} retired, \{failed} failed, \{pending} pending",
  ]
  for row in rows {
    let name = @devkit.sanitize_label(row.name)
    let line = match row.state {
      Connected(stats) => {
        let tool_word = if stats.tools == 1 { "tool" } else { "tools" }
        "- \{name}: connected, \{stats.tools} \{tool_word} (health=\{mcp_health_label(stats.health)}, generation=\{stats.generation}, in_flight=\{stats.in_flight}, accepted=\{stats.accepted}, processed=\{stats.processed}, abandoned=\{stats.abandoned})"
      }
      Retired => "- \{name}: retired"
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
      Connected(stats) => {
        fields.push(("tools", Json::number(stats.tools.to_double())))
        fields.push(("health", Json::string(mcp_health_label(stats.health))))
        fields.push(("generation", Json::number(stats.generation.to_double())))
        fields.push(("in_flight", Json::number(stats.in_flight.to_double())))
        fields.push(("accepted", Json::number(stats.accepted.to_double())))
        fields.push(("processed", Json::number(stats.processed.to_double())))
        fields.push(("abandoned", Json::number(stats.abandoned.to_double())))
      }
      Retired => ()
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
async fn MCPToolBridge::command_status(
  self : MCPToolBridge,
) -> @posoco.CommandOutcome noraise {
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
