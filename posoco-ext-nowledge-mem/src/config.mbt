///|
const NMEM_DEFAULT_API_URL : String = "http://127.0.0.1:14242"

///|
/// First trimmed non-empty value among `candidates`; `None` and blank entries
/// are skipped. This is the chain primitive behind upstream `readConfigValue`.
fn first_present(candidates : Array[String?]) -> String? {
  let mut found : String? = None
  for candidate in candidates {
    if found is None {
      match candidate {
        Some(raw) => {
          let value = raw.trim().to_owned()
          if value != "" {
            found = Some(value)
          }
        }
        None => ()
      }
    }
  }
  found
}

///|
/// First trimmed non-empty value among `names` from the env lookup.
fn env_string(env_get : (String) -> String?, names : Array[String]) -> String? {
  let candidates : Array[String?] = []
  for name in names {
    candidates.push(env_get(name))
  }
  first_present(candidates)
}

///|
/// First trimmed non-empty string value among `keys` of the parsed config
/// object; non-string entries are ignored.
fn config_string(config : Map[String, Json], keys : Array[String]) -> String? {
  let candidates : Array[String?] = []
  for key in keys {
    if config.contains(key) {
      match config[key] {
        Json::String(value) => candidates.push(Some(value))
        _ => ()
      }
    }
  }
  first_present(candidates)
}

///|
/// Parse the ~/.nowledge-mem/config.json text. Malformed JSON or a non-object
/// document yields an empty object (upstream `readSharedConfig` semantics).
fn parse_config_object(text : String?) -> Map[String, Json] {
  match text {
    None => Map::from_array([])
    Some(raw) =>
      try @json.parse(raw) catch {
        _ => Map::from_array([])
      } noraise {
        Json::Object(fields) => fields
        _ => Map::from_array([])
      }
  }
}

///|
/// Drop the trailing run of "/" characters (upstream `.replace(/\/+$/, "")`).
/// Boundaries are ASCII-safe: '/' is never half of a surrogate pair.
fn strip_trailing_slashes(url : String) -> String {
  let mut end = url.length()
  while end > 0 && url[end - 1] == '/' {
    end = end - 1
  }
  url[0:end].to_owned()
}

///|
/// Resolve Nowledge Mem configuration from an env lookup function and the
/// already-read text of ~/.nowledge-mem/config.json (`None` = absent). The IO
/// stays with the caller (runner milestone); this function is pure.
///
/// Priority per key: env var > config.json entry (camelCase and snake_case
/// both accepted) > default. All values are trimmed; blanks count as missing.
///
/// `source_app~` is the host product identity (the extension is a reusable
/// library — the label belongs to the embedding product, not to Posoco); the
/// env var `NMEM_PLUGIN_SOURCE_APP` overrides it, there is no built-in
/// default.
pub fn NmemConfig::resolve(
  env_get : (String) -> String?,
  config_file_text : String?,
  source_app~ : String,
) -> NmemConfig {
  let config = parse_config_object(config_file_text)
  let api_url_source = first_present([
    env_string(env_get, ["NMEM_API_URL"]),
    config_string(config, ["apiUrl", "api_url"]),
  ])
  let api_url = strip_trailing_slashes(
    match api_url_source {
      Some(url) => url
      None => NMEM_DEFAULT_API_URL
    },
  )
  {
    api_url,
    api_key: first_present([
      env_string(env_get, ["NMEM_API_KEY"]),
      config_string(config, ["apiKey", "api_key"]),
    ]),
    space: first_present([
      env_string(env_get, ["NMEM_SPACE", "NMEM_SPACE_ID"]),
      config_string(config, ["space", "spaceId", "space_id"]),
    ]),
    agent_id: first_present([
      env_string(env_get, ["NMEM_AGENT_ID"]),
      config_string(config, ["agentId", "agent_id"]),
    ]),
    host_agent_id: first_present([
      env_string(env_get, ["NMEM_HOST_AGENT_ID"]),
      config_string(config, ["hostAgentId", "host_agent_id"]),
    ]),
    source_app: match env_string(env_get, ["NMEM_PLUGIN_SOURCE_APP"]) {
      Some(app) => app
      None => source_app
    },
  }
}
