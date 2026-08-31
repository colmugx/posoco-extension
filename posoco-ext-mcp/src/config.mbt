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
//   http:  { "url": "http://host/mcp", "type": "http", "auth": "oauth" }
// `type` is optional; the transport is inferred from which of `command`/`url`
// is present. `auth` is http-only. `legacy` is an optional boolean tri-state
// for the protocol era: absent = Auto (probe, legacy fallback allowed),
// true = Legacy (2025-11-25 initialize, probe skipped), false = Modern
// (probe, legacy fallback refused). Env values are literals — no ${VAR}
// expansion.

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
/// Extract an optional non-negative integer knob (`timeout_ms`,
/// `max_reconnects`; 0 = disabled). Absent → `Ok(None)` and the constructor
/// defaults apply. Fractional values and magnitudes beyond `Int` are rejected
/// so a JSON typo cannot silently disable a knob via truncation.
fn int_field(
  entry : Map[String, Json],
  key : String,
  server : String,
) -> Result[Int?, String] {
  match entry.get(key) {
    None => Ok(None)
    Some(Json::Number(value, ..)) =>
      if value != value.floor() {
        Err(
          "mcp.json server '\{@devkit.sanitize_label(server)}': '\{key}' must be an integer",
        )
      } else if value < 0.0 {
        Err(
          "mcp.json server '\{@devkit.sanitize_label(server)}': '\{key}' must not be negative",
        )
      } else if value > 2147483647.0 {
        Err(
          "mcp.json server '\{@devkit.sanitize_label(server)}': '\{key}' is out of range (max 2147483647)",
        )
      } else {
        Ok(Some(value.to_int()))
      }
    Some(_) =>
      Err(
        "mcp.json server '\{@devkit.sanitize_label(server)}': '\{key}' must be an integer",
      )
  }
}

///|
/// Parse the optional `auth` key. Absent → NoAuth; `"oauth"` → OAuth (the
/// host acquires tokens at runtime). Stdio entries reject the key outright —
/// their secrets travel on `env`, so an `auth` key there signals a confused
/// config rather than a runnable one.
fn parse_server_auth(
  fields : Map[String, Json],
  server : String,
  use_stdio~ : Bool,
) -> Result[ServerAuth, String] {
  match fields.get("auth") {
    None => Ok(ServerAuth::NoAuth)
    Some(Json::String(value)) =>
      if use_stdio {
        Err(
          "mcp.json server '\{@devkit.sanitize_label(server)}': 'auth' is not valid for stdio servers (secrets go through 'env')",
        )
      } else if value == "oauth" {
        Ok(ServerAuth::OAuth)
      } else {
        Err(
          "mcp.json server '\{@devkit.sanitize_label(server)}': unsupported auth '\{@devkit.sanitize_label(value)}' (expected 'oauth')",
        )
      }
    Some(_) =>
      Err(
        "mcp.json server '\{@devkit.sanitize_label(server)}': 'auth' must be a string",
      )
  }
}

///|
/// Parse the optional `legacy` key, a boolean tri-state for the client's
/// protocol era: absent → `Auto` (probe the server, legacy fallback allowed),
/// `true` → `Legacy` (dial the 2025-11-25 legacy initialize directly, probe
/// skipped), `false` → `Modern` (probe, legacy fallback refused). Only
/// servers known to speak the legacy protocol should set `true`.
fn parse_server_era(
  fields : Map[String, Json],
  server : String,
) -> Result[@client.ProtocolEra, String] {
  match fields.get("legacy") {
    None => Ok(@client.ProtocolEra::Auto)
    Some(Json::True) => Ok(@client.ProtocolEra::Legacy)
    Some(Json::False) => Ok(@client.ProtocolEra::Modern)
    Some(_) =>
      Err(
        "mcp.json server '\{@devkit.sanitize_label(server)}': 'legacy' must be a boolean",
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
  // Resilience knobs shared by both transports. Absent keys forward None so
  // the constructor defaults stay the single source for 30_000 / 1.
  let timeout_ms = match int_field(fields, "timeout_ms", server) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let max_reconnects = match int_field(fields, "max_reconnects", server) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let era = match parse_server_era(fields, server) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if use_stdio {
    let cmd = string_field(fields, "command", server)
    let args = string_array_field(fields, "args", server)
    let env = env_field(fields, server)
    let auth = parse_server_auth(fields, server, use_stdio=true)
    match (cmd, args, env, auth) {
      (Ok(cmd), Ok(args), Ok(env), Ok(auth)) => {
        let transport = @transport.StdioClientTransport::StdioClientTransport(
          cmd~,
          args~,
          extra_env=env,
        )
        Ok(
          MCPServerConfig::MCPServerConfig(
            name=server,
            transport=@transport.AnyTransport::StdioClient(transport),
            auth~,
            era~,
            timeout_ms?,
            max_reconnects?,
          ),
        )
      }
      (Err(message), _, _, _)
      | (_, Err(message), _, _)
      | (_, _, Err(message), _)
      | (_, _, _, Err(message)) => Err(message)
    }
  } else {
    let url = string_field(fields, "url", server)
    let auth_token = match fields.get("auth_token") {
      None => Ok("")
      Some(Json::String(value)) => expand_env_vars(value, server)
      Some(_) =>
        Err(
          "mcp.json server '\{@devkit.sanitize_label(server)}': 'auth_token' must be a string",
        )
    }
    let auth = parse_server_auth(fields, server, use_stdio=false)
    match (url, auth_token, auth) {
      (Ok(url), Ok(auth_token), Ok(auth)) => {
        let transport = @transport.HttpClientTransport::HttpClientTransport(
          url,
          auth_token~,
        )
        Ok(
          MCPServerConfig::MCPServerConfig(
            name=server,
            transport=@transport.AnyTransport::HttpClient(transport),
            auth~,
            era~,
            timeout_ms?,
            max_reconnects?,
          ),
        )
      }
      (Err(message), _, _) | (_, Err(message), _) | (_, _, Err(message)) =>
        Err(message)
    }
  }
}

///|
/// Expand `${VAR}` references against the process environment so secrets
/// stay out of mcp.json. An unset variable is a loud configuration error —
/// the server must not silently connect unauthenticated.
fn expand_env_vars(
  template : String,
  server : String,
) -> Result[String, String] {
  let out = StringBuilder()
  let mut i = 0
  let mut plain_start = 0
  while i < template.length() {
    if template[i] == '$' && i + 1 < template.length() && template[i + 1] == '{' {
      // Scan for the closing brace from inside the reference.
      let mut end = -1
      let mut j = i + 2
      while j < template.length() {
        if template[j] == '}' {
          end = j
          break
        }
        j += 1
      }
      if end < 0 {
        return Err(
          "mcp.json server '\{@devkit.sanitize_label(server)}': unterminated '${' in 'auth_token'",
        )
      }
      out.write_string(template[plain_start:i].to_owned())
      let name = template[i + 2:end].to_owned()
      let mut name_ok = name.length() > 0
      for c in name {
        if !((c >= 'a' && c <= 'z') ||
          (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') ||
          c == '_') {
          name_ok = false
        }
      }
      if !name_ok {
        return Err(
          "mcp.json server '\{@devkit.sanitize_label(server)}': invalid variable name in 'auth_token'",
        )
      }
      match @env.get_env_var(name) {
        Some(value) => {
          out.write_string(value)
          i = end + 1
          plain_start = i
          continue
        }
        None =>
          return Err(
            "mcp.json server '\{@devkit.sanitize_label(server)}': environment variable '\{@devkit.sanitize_label(name)}' (auth_token) is not set",
          )
      }
    }
    i += 1
  }
  out.write_string(template[plain_start:].to_owned())
  Ok(out.to_string())
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
