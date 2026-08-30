///|
/// Home-relative path of the shared Nowledge Mem config file — the same
/// file every Nowledge integration reads (env vars still outrank it).
const NMEM_CONFIG_REL : String = ".nowledge-mem/config.json"

///|
/// `local` when the sync base points at this machine, `remote` otherwise
/// (nmem cloud or a LAN server) — the status line that answers "where am I
/// actually connected".
fn nmem_mode(api_url : String) -> String {
  if api_url.contains("//127.0.0.1") ||
    api_url.contains("//localhost") ||
    api_url.contains("//[::1]") {
    "local"
  } else {
    "remote"
  }
}

///|
/// `/nmem` status: the connection picture — the tool channel (always MCP
/// since the CLI runner retired), the thread-sync channel, the host
/// identity riding every call, and any env override that outranks the
/// config file. Returns the text report and its structured twin.
async fn NowledgeMem::nmem_status_report(self : NowledgeMem) -> (String, Json) {
  let lines : Array[String] = []
  let mode = match self.config {
    Some(config) => nmem_mode(config.api_url)
    None => "unresolved"
  }
  let mcp_url = match self.config {
    Some(config) => config.mcp_url
    None => "(not resolved — on_start not run)"
  }
  let api_url = match self.config {
    Some(config) => config.api_url
    None => "(not resolved — on_start not run)"
  }
  lines.push("tools: mcp \{mcp_url}")
  lines.push("sync: \{api_url} (\{mode})")
  let probe : Result[String, String] = try
    self.mcp.probe(timeout_ms=NMEM_COMMAND_STATUS_TIMEOUT_MS)
  catch {
    err => Err("probe raised: " + err.to_string())
  } noraise {
    value => value
  }
  let connected = match probe {
    Ok(report) => {
      lines.push(
        "mcp: connected (\{take_prefix(report, NMEM_STATUS_REPORT_CHARS)})",
      )
      true
    }
    Err(detail) => {
      lines.push(
        "mcp: unreachable (\{take_prefix(detail, NMEM_TOOL_ERROR_CHARS)})",
      )
      false
    }
  }
  let source_app = match self.config {
    Some(config) => config.source_app
    None => self.source_app
  }
  lines.push("identity: source_app=\{source_app}")
  match self.config {
    Some({ space: Some(space), .. }) =>
      lines.push("  space=\{space} (applies to sync bodies and tool calls)")
    _ => ()
  }
  for
    name in [
      "NMEM_API_URL", "NMEM_MCP_URL", "NMEM_API_KEY", "NMEM_PLUGIN_SOURCE_APP",
    ] {
    match runner_get_env(name) {
      Some(value) =>
        lines.push("env override: \{name}=\{value} (wins over the config file)")
      None => ()
    }
  }
  let structured = Json::object({
    "tool_channel": Json::string("mcp"),
    "mcp_url": Json::string(mcp_url),
    "api_url": Json::string(api_url),
    "mode": Json::string(mode),
    "connected": Json::boolean(connected),
    "source_app": Json::string(source_app),
  })
  (lines.join("\n"), structured)
}

///|
/// Which endpoint a `/nmem` setter switches.
priv enum NmemUrlKind {
  ApiBase
  McpEndpoint
}

///|
/// Validate and normalize a user-supplied endpoint: trimmed, trailing
/// slashes stripped, and shaped like `scheme://host[:port]/...` (the same
/// authority check the HTTP transport applies).
fn nmem_clean_url(raw : String) -> String? {
  let stripped = strip_trailing_slashes(raw.trim().to_owned())
  if split_url(stripped) is Some(_) {
    Some(stripped)
  } else {
    None
  }
}

///|
/// Switch an endpoint at runtime: flush pending syncs to the OLD address
/// first (staged transcripts belong where they were recorded), update the
/// resolved config (an api-base switch re-derives the MCP endpoint), hand
/// the new endpoint to the lazy MCP client (its live connection retires,
/// the next call reconnects), persist the value into the shared config
/// file, and probe the new endpoint for the feedback. Returns the feedback
/// text; the runtime switch happens even when persistence fails.
async fn NowledgeMem::nmem_set_url(
  self : NowledgeMem,
  url : String,
  kind~ : NmemUrlKind,
) -> String {
  let (label, persist_camel, persist_snake) = match kind {
    ApiBase => ("api base", "apiUrl", "api_url")
    McpEndpoint => ("mcp endpoint", "mcpUrl", "mcp_url")
  }
  let lines : Array[String] = []
  // Best-effort drain: a failed flush keeps the staged syncs on the old
  // address (their requests carry it); the note makes that visible.
  let flushed : Bool = try {
    self.flush_pending()
    true
  } catch {
    _ => false
  } noraise {
    ok => ok
  }
  if !flushed {
    lines.push(
      "warning: pre-switch drain raised; staged syncs stay on the old address",
    )
  }
  let updated : NmemConfig = match (kind, self.config) {
    (ApiBase, Some(config)) =>
      { ..config, api_url: url, mcp_url: normalize_mcp_path(url), }
    (ApiBase, None) =>
      {
        api_url: url,
        mcp_url: normalize_mcp_path(url),
        api_key: None,
        space: None,
        agent_id: None,
        host_agent_id: None,
        source_app: self.source_app,
      }
    (McpEndpoint, Some(config)) => { ..config, mcp_url: url, }
    (McpEndpoint, None) =>
      {
        api_url: NMEM_DEFAULT_API_URL,
        mcp_url: url,
        api_key: None,
        space: None,
        agent_id: None,
        host_agent_id: None,
        source_app: self.source_app,
      }
  }
  self.config = Some(updated)
  self.mcp.configure(
    url=updated.mcp_url,
    auth_token=updated.api_key,
    name=updated.source_app,
  )
  lines.push("\{label} switched to \{url}")
  match self.persist_config_value(persist_camel, persist_snake, url) {
    Ok(_) => lines.push("persisted to ~/\{NMEM_CONFIG_REL}")
    Err(detail) =>
      lines.push(
        "warning: persist failed (\{detail}); the switch lasts until shutdown",
      )
  }
  let probe : Result[String, String] = try
    self.mcp.probe(timeout_ms=NMEM_COMMAND_STATUS_TIMEOUT_MS)
  catch {
    err => Err(err.to_string())
  } noraise {
    value => value
  }
  match probe {
    Ok(report) =>
      lines.push(
        "mcp: connected (\{take_prefix(report, NMEM_STATUS_REPORT_CHARS)})",
      )
    Err(detail) =>
      lines.push(
        "mcp: unreachable (\{take_prefix(detail, NMEM_TOOL_ERROR_CHARS)})",
      )
  }
  lines.join("\n")
}

///|
/// Merge one key into the shared `~/.nowledge-mem/config.json`, preserving
/// every other entry and the file's existing key spelling (snake_case
/// files stay snake_case). A present-but-malformed file is refused rather
/// than clobbered.
async fn NowledgeMem::persist_config_value(
  self : NowledgeMem,
  camel : String,
  snake : String,
  value : String,
) -> Result[Unit, String] {
  let text = NmemPlatform::read_home_file(self.platform, NMEM_CONFIG_REL)
  let fields : Map[String, Json] = match text {
    None => Map::from_array([])
    Some(raw) => {
      let parsed = @json.parse(raw) catch {
        _ =>
          return Err(
            "\{NMEM_CONFIG_REL} is not valid JSON; refusing to overwrite",
          )
      }
      match parsed {
        Json::Object(fields) => fields
        _ =>
          return Err(
            "\{NMEM_CONFIG_REL} is not a JSON object; refusing to overwrite",
          )
      }
    }
  }
  let key = if fields.contains(snake) { snake } else { camel }
  fields[key] = Json::string(value)
  NmemPlatform::write_home_file(
    self.platform,
    NMEM_CONFIG_REL,
    Json::object(fields).stringify(),
  )
}

///|
/// One parsed `/nmem` invocation: an action plus its optional value.
priv struct NmemArgs {
  action : String
  value : String?
}

///|
/// `/nmem` accepts no arguments (status), a bare string
/// (`"status"`, `"url https://mem.example.com"`), or an
/// `{action, value}` object — the same contract shapes as `/memory`.
fn parse_nmem_args(args : Json) -> NmemArgs? raise @posoco.CommandError {
  match args {
    Json::Null => None
    Json::String(raw) => {
      let trimmed = raw.trim().to_owned()
      if trimmed == "" {
        None
      } else {
        match trimmed.find(" ") {
          Some(at) => {
            let value = trimmed[at + 1:].trim().to_owned()
            if value == "" {
              raise @posoco.CommandError::InvalidArgs(
                reason="/nmem: '\{trimmed[:at].to_owned()}' needs a URL argument",
              )
            }
            Some({ action: trimmed[:at].to_owned(), value: Some(value), })
          }
          None => Some({ action: trimmed, value: None, })
        }
      }
    }
    Json::Object(fields) =>
      match fields.get("action") {
        None => None
        Some(Json::String(action)) => {
          let trimmed = action.trim().to_owned()
          if trimmed == "" {
            return None
          }
          let value = match fields.get("value") {
            Some(Json::String(value)) => {
              let trimmed_value = value.trim().to_owned()
              if trimmed_value == "" {
                raise @posoco.CommandError::InvalidArgs(
                  reason="/nmem: '\{trimmed}' needs a non-empty value",
                )
              }
              Some(trimmed_value)
            }
            Some(_) =>
              raise @posoco.CommandError::InvalidArgs(
                reason="/nmem: 'value' must be a string",
              )
            None => None
          }
          Some({ action: trimmed, value, })
        }
        Some(_) =>
          raise @posoco.CommandError::InvalidArgs(
            reason="/nmem: 'action' must be a string",
          )
      }
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/nmem expects no arguments, an action string, or {action, value}",
      )
  }
}

///|
fn nmem_usage() -> String {
  (
    #|/nmem — Nowledge Mem connection management
    #|  /nmem [status]   connection status: tool channel (MCP), sync channel, identity, env overrides
    #|  /nmem url <api>  switch the service base URL (sync + derived MCP endpoint); persists to ~/.nowledge-mem/config.json
    #|  /nmem mcp <url>  override the MCP endpoint only; persists to ~/.nowledge-mem/config.json
  )
}

///|
/// `/nmem` — the connection management face (the `/memory` command stays
/// the sync/queue diagnostics face). Status lands as a toast; the setters
/// flush staged syncs to the old address first, reconfigure the lazy MCP
/// client, persist into the shared config file, and probe the new endpoint.
async fn NowledgeMem::invoke_nmem(
  self : NowledgeMem,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match parse_nmem_args(args) {
    None | Some({ action: "status", .. }) => {
      let reported : (String, Json)? = try self.nmem_status_report() catch {
        _ => None
      } noraise {
        pair => Some(pair)
      }
      match reported {
        Some((report, structured)) =>
          @posoco.CommandOutcome::Success(
            feedback=report,
            structured=Some(structured),
            ui_hint=Some(@posoco.UiHint::Toast),
          )
        None =>
          @posoco.CommandOutcome::Failure(
            reason="/nmem status failed: the probe raised",
          )
      }
    }
    Some({ action: "url", value: Some(raw), }) =>
      match nmem_clean_url(raw) {
        Some(url) => {
          let feedback : String = try
            self.nmem_set_url(url, kind=ApiBase)
          catch {
            err =>
              return @posoco.CommandOutcome::Failure(
                reason="/nmem url failed: \{err.to_string()}",
              )
          } noraise {
            text => text
          }
          @posoco.CommandOutcome::Success(
            feedback~,
            structured=None,
            ui_hint=Some(@posoco.UiHint::Toast),
          )
        }
        None =>
          @posoco.CommandOutcome::Failure(
            reason="/nmem url: '\{raw}' is not an http(s) URL",
          )
      }
    Some({ action: "mcp", value: Some(raw), }) =>
      match nmem_clean_url(raw) {
        Some(url) => {
          let feedback : String = try
            self.nmem_set_url(url, kind=McpEndpoint)
          catch {
            err =>
              return @posoco.CommandOutcome::Failure(
                reason="/nmem mcp failed: \{err.to_string()}",
              )
          } noraise {
            text => text
          }
          @posoco.CommandOutcome::Success(
            feedback~,
            structured=None,
            ui_hint=Some(@posoco.UiHint::Toast),
          )
        }
        None =>
          @posoco.CommandOutcome::Failure(
            reason="/nmem mcp: '\{raw}' is not an http(s) URL",
          )
      }
    Some({ action: "url" | "mcp", value: None, }) =>
      @posoco.CommandOutcome::Failure(
        reason="/nmem: 'url' and 'mcp' need a URL argument\n\{nmem_usage()}",
      )
    Some({ action: other, .. }) =>
      @posoco.CommandOutcome::Failure(
        reason="unknown /nmem action '\{other}'\n\{nmem_usage()}",
      )
  }
}

///|
/// The `/nmem` command definition.
fn nmem_command_def() -> @posoco.CommandDef {
  {
    id: "nmem",
    label: "Nowledge Mem Connection",
    description: "Manage the Nowledge Mem connection: status (tool/sync channels, identity), switch the service URL (nmem cloud), override the MCP endpoint",
    category: "memory",
    ctype: @posoco.CommandType::Action,
    params: [
      @posoco.CommandParam::{
        name: "action",
        label: "Action",
        description: "status / url / mcp (default: status)",
        ptype: @posoco.ParamType::Str,
        required: false,
        default: None,
        choices: Some(["status", "url", "mcp"]),
        positional: true,
      },
      @posoco.CommandParam::{
        name: "value",
        label: "URL",
        description: "Target URL for url/mcp (e.g. https://mem.example.com)",
        ptype: @posoco.ParamType::Str,
        required: false,
        default: None,
        choices: None,
        positional: true,
      },
    ],
    aliases: [],
    shortcut: None,
    icon: None,
    visible: true,
    metadata: None,
  }
}
