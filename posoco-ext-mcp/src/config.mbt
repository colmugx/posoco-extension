///|
// Self-governing mcp.json discovery and parsing.
//
// Two levels are consulted, mirroring the mainstream (Claude Code / VS Code)
// convention `{"mcpServers": {...}}`:
//   - project: `<cwd>/.mcp.json`
//   - user:    `<home>/.cetas/mcp.json`
// A missing file at either level contributes nothing; a present-but-malformed
// file is a loud, sanitized configuration error. On name collision the
// project entry wins over the user entry.
//
// Server entry shapes (unknown keys are ignored for forward compatibility):
//   stdio: { "command": "npx", "args": ["..."], "env": {"K": "V"}, "type": "stdio" }
//   http:  { "url": "http://host/mcp", "type": "http" }
// `type` is optional; the transport is inferred from which of `command`/`url`
// is present. Env values are literals — no ${VAR} expansion.

///|
/// When the bridge connects the servers declared by mcp.json.
pub(all) enum LoadMode {
  /// Connect every server as soon as the host activates the bridge, before
  /// the Agent catalog is composed.
  Eager
  /// Defer connection to the first turn (`Lifecycle::on_start`); the tool
  /// catalog is admitted through the runtime seam (`McpCatalogSource`) at
  /// the same turn's prompt boundary.
  Lazy
} derive(Eq)

///|
/// Project-level mcp.json path: `<cwd>/.mcp.json`.
fn project_mcp_json_path(cwd : String) -> String {
  if cwd == "" {
    ".mcp.json"
  } else if cwd.has_suffix("/") {
    cwd + ".mcp.json"
  } else {
    cwd + "/.mcp.json"
  }
}

///|
/// User-level mcp.json path: `<home>/.cetas/mcp.json`.
fn user_mcp_json_path(home : String) -> String {
  let base = if home == "" {
    "."
  } else if home.has_suffix("/") {
    home[:home.length() - 1].to_owned()
  } else {
    home
  }
  base + "/.cetas/mcp.json"
}

///|
/// Read one mcp.json. `Ok(None)` = the file does not exist (not an error);
/// `Err` = it exists but cannot be read or is not valid JSON. Errors carry
/// the path label only — file contents never leak into messages.
async fn read_mcp_json(
  path : String,
  label : String,
) -> Result[Json?, String] noraise {
  match read_file_text(path) {
    Missing => Ok(None)
    IoFailed => Err("mcp.json read failed for '\{label}'")
    NotUtf8 => Err("mcp.json is not valid UTF-8: '\{label}'")
    Text(text) => {
      let json = @json.parse(text) catch {
        _ => return Err("mcp.json is not valid JSON: '\{label}'")
      }
      Ok(Some(json))
    }
  }
}

///|
/// Extract a required string field.
fn string_field(
  entry : Map[String, Json],
  key : String,
  server : String,
) -> Result[String, String] {
  match entry.get(key) {
    Some(Json::String(value)) =>
      if value == "" {
        Err(
          "mcp.json server '\{@devkit.sanitize_label(server)}': '\{key}' must not be empty",
        )
      } else {
        Ok(value)
      }
    Some(_) =>
      Err(
        "mcp.json server '\{@devkit.sanitize_label(server)}': '\{key}' must be a string",
      )
    None =>
      Err(
        "mcp.json server '\{@devkit.sanitize_label(server)}': missing '\{key}'",
      )
  }
}

///|
/// Extract an optional `Array[String]` field.
fn string_array_field(
  entry : Map[String, Json],
  key : String,
  server : String,
) -> Result[Array[String], String] {
  match entry.get(key) {
    None => Ok([])
    Some(Json::Array(items)) => {
      let values : Array[String] = []
      for item in items {
        match item {
          Json::String(value) => values.push(value)
          _ =>
            return Err(
              "mcp.json server '\{@devkit.sanitize_label(server)}': '\{key}' must be an array of strings",
            )
        }
      }
      Ok(values)
    }
    Some(_) =>
      Err(
        "mcp.json server '\{@devkit.sanitize_label(server)}': '\{key}' must be an array",
      )
  }
}

///|
/// Extract an optional string→string `env` map.
fn env_field(
  entry : Map[String, Json],
  server : String,
) -> Result[Map[String, String], String] {
  match entry.get("env") {
    None => Ok(Map::from_array([]))
    Some(Json::Object(fields)) => {
      let env : Map[String, String] = Map::from_array([])
      for key, value in fields {
        match value {
          Json::String(text) => env[key] = text
          _ =>
            return Err(
              "mcp.json server '\{@devkit.sanitize_label(server)}': 'env' values must be strings",
            )
        }
      }
      Ok(env)
    }
    Some(_) =>
      Err(
        "mcp.json server '\{@devkit.sanitize_label(server)}': 'env' must be an object",
      )
  }
}

///|
/// Parse one server entry into a transport-ready config.
fn parse_server_entry(
  server : String,
  entry : Json,
) -> Result[MCPServerConfig, String] {
  if server == "" {
    return Err("mcp.json: server name must not be empty")
  }
  let fields = match entry {
    Json::Object(fields) => fields
    _ =>
      return Err(
        "mcp.json server '\{@devkit.sanitize_label(server)}': entry must be an object",
      )
  }
  let declared_type = match fields.get("type") {
    None => None
    Some(Json::String(value)) => Some(value)
    Some(_) =>
      return Err(
        "mcp.json server '\{@devkit.sanitize_label(server)}': 'type' must be a string",
      )
  }
  let has_command = fields.get("command") is Some(_)
  let has_url = fields.get("url") is Some(_)
  if has_command && has_url {
    return Err(
      "mcp.json server '\{@devkit.sanitize_label(server)}': declare either 'command' (stdio) or 'url' (http), not both",
    )
  }
  // With an explicit type the field check below reports the precise
  // missing field; without one, say what the entry needs at all.
  if declared_type is None && !has_command && !has_url {
    return Err(
      "mcp.json server '\{@devkit.sanitize_label(server)}': declare 'command' (stdio) or 'url' (http)",
    )
  }
  // Transport selection: explicit `type` wins; otherwise infer from the
  // present field. A mismatch between `type` and fields is rejected so a
  // typo cannot silently pick the wrong transport.
  let use_stdio = match declared_type {
    Some("stdio") => true
    Some("http") => false
    Some(other) =>
      return Err(
        "mcp.json server '\{@devkit.sanitize_label(server)}': unsupported type '\{@devkit.sanitize_label(other)}' (expected 'stdio' or 'http')",
      )
    None => has_command
  }
  if use_stdio && !has_command {
    return Err(
      "mcp.json server '\{@devkit.sanitize_label(server)}': stdio server needs 'command'",
    )
  }
  if !use_stdio && !has_url {
    return Err(
      "mcp.json server '\{@devkit.sanitize_label(server)}': http server needs 'url'",
    )
  }
  if use_stdio {
    let cmd = string_field(fields, "command", server)
    let args = string_array_field(fields, "args", server)
    let env = env_field(fields, server)
    match (cmd, args, env) {
      (Ok(cmd), Ok(args), Ok(env)) => {
        let transport = @transport.StdioClientTransport::StdioClientTransport(
          cmd~,
          args~,
          extra_env=env,
        )
        Ok({
          name: server,
          transport: @transport.AnyTransport::StdioClient(transport),
        })
      }
      (Err(message), _, _) | (_, Err(message), _) | (_, _, Err(message)) =>
        Err(message)
    }
  } else {
    let url = string_field(fields, "url", server)
    match url {
      Ok(url) => {
        let transport = @transport.HttpClientTransport::HttpClientTransport(url)
        Ok({
          name: server,
          transport: @transport.AnyTransport::HttpClient(transport),
        })
      }
      Err(message) => Err(message)
    }
  }
}

///|
/// Parse one mcp.json document into server configs.
fn parse_mcp_document(
  doc : Json,
  label : String,
) -> Result[Array[MCPServerConfig], String] {
  let fields = match doc {
    Json::Object(fields) => fields
    _ => return Err("mcp.json must be an object: '\{label}'")
  }
  let servers = match fields.get("mcpServers") {
    None => return Ok([])
    Some(Json::Object(servers)) => servers
    Some(_) => return Err("mcpServers must be an object: '\{label}'")
  }
  let configs : Array[MCPServerConfig] = []
  for server, entry in servers {
    let config = parse_server_entry(server, entry)
    match config {
      Ok(value) => configs.push(value)
      Err(message) => return Err(message)
    }
  }
  Ok(configs)
}

///|
/// Merge user-level and project-level configs. Same-name servers: the
/// project entry replaces the user entry (project is more specific).
fn merge_server_configs(
  user : Array[MCPServerConfig],
  project : Array[MCPServerConfig],
) -> Array[MCPServerConfig] {
  let by_name : Map[String, MCPServerConfig] = Map::from_array([])
  let order : Array[String] = []
  for config in user {
    if !by_name.contains(config.name) {
      order.push(config.name)
    }
    by_name[config.name] = config
  }
  for config in project {
    if !by_name.contains(config.name) {
      order.push(config.name)
    }
    by_name[config.name] = config
  }
  order.map(name => by_name[name])
}

///|
/// Discover and parse both mcp.json levels. A missing file contributes
/// nothing; malformed content fails loud with a sanitized message.
async fn discover_mcp_servers(
  cwd : String,
  home : String,
) -> Result[Array[MCPServerConfig], String] noraise {
  let project_path = project_mcp_json_path(cwd)
  let user_path = user_mcp_json_path(home)
  let user_doc = read_mcp_json(user_path, "user")
  let project_doc = read_mcp_json(project_path, "project")
  match (user_doc, project_doc) {
    (Err(message), _) | (_, Err(message)) => Err(message)
    (Ok(user_doc), Ok(project_doc)) => {
      let user : Array[MCPServerConfig] = match user_doc {
        Some(doc) =>
          match parse_mcp_document(doc, "user") {
            Ok(configs) => configs
            Err(message) => return Err(message)
          }
        None => []
      }
      let project : Array[MCPServerConfig] = match project_doc {
        Some(doc) =>
          match parse_mcp_document(doc, "project") {
            Ok(configs) => configs
            Err(message) => return Err(message)
          }
        None => []
      }
      Ok(merge_server_configs(user, project))
    }
  }
}
