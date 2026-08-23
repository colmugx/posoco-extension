///|
fn env_of(entries : Array[(String, String)]) -> (String) -> String? {
  let values = Map::from_array(entries)
  fn(name : String) -> String? {
    if values.contains(name) {
      Some(values[name])
    } else {
      None
    }
  }
}

///|
test "resolve: defaults when nothing is set; source_app comes from the parameter" {
  let config = NmemConfig::resolve(env_of([]), None, source_app="cetas")
  inspect(config.api_url, content="http://127.0.0.1:14242")
  debug_inspect(config.api_key, content="None")
  debug_inspect(config.space, content="None")
  debug_inspect(config.agent_id, content="None")
  debug_inspect(config.host_agent_id, content="None")
  inspect(config.source_app, content="cetas")
}

///|
test "resolve: env api_url beats config file; value trimmed, slashes stripped" {
  let config = NmemConfig::resolve(
    env_of([("NMEM_API_URL", " https://remote.example.com/// ")]),
    Some("{\"apiUrl\": \"http://file.example.com/\"}"),
    source_app="cetas",
  )
  inspect(config.api_url, content="https://remote.example.com")
}

///|
test "resolve: config file api_url used when env absent (camelCase)" {
  let config = NmemConfig::resolve(
    env_of([]),
    Some("{\"apiUrl\": \"http://file.example.com//\"}"),
    source_app="cetas",
  )
  inspect(config.api_url, content="http://file.example.com")
}

///|
test "resolve: config file api_url snake_case accepted" {
  let config = NmemConfig::resolve(
    env_of([]),
    Some("{\"api_url\": \"http://snake.example.com\"}"),
    source_app="cetas",
  )
  inspect(config.api_url, content="http://snake.example.com")
}

///|
test "resolve: api_key chain env > apiKey > api_key" {
  let from_env = NmemConfig::resolve(
    env_of([("NMEM_API_KEY", " env-key ")]),
    Some("{\"apiKey\": \"file-key\"}"),
    source_app="cetas",
  )
  debug_inspect(from_env.api_key, content="Some(\"env-key\")")
  let from_camel = NmemConfig::resolve(
    env_of([]),
    Some("{\"apiKey\": \"file-key\"}"),
    source_app="cetas",
  )
  debug_inspect(from_camel.api_key, content="Some(\"file-key\")")
  let from_snake = NmemConfig::resolve(
    env_of([]),
    Some("{\"api_key\": \"file-key\"}"),
    source_app="cetas",
  )
  debug_inspect(from_snake.api_key, content="Some(\"file-key\")")
}

///|
test "resolve: space chain NMEM_SPACE > NMEM_SPACE_ID > space > spaceId > space_id" {
  let both_env = NmemConfig::resolve(
    env_of([("NMEM_SPACE", "s1"), ("NMEM_SPACE_ID", "s2")]),
    Some("{\"space\": \"s3\"}"),
    source_app="cetas",
  )
  debug_inspect(both_env.space, content="Some(\"s1\")")
  let id_env = NmemConfig::resolve(
    env_of([("NMEM_SPACE_ID", "s2")]),
    Some("{\"space\": \"s3\"}"),
    source_app="cetas",
  )
  debug_inspect(id_env.space, content="Some(\"s2\")")
  let cfg_space = NmemConfig::resolve(
    env_of([]),
    Some("{\"space\": \"s3\"}"),
    source_app="cetas",
  )
  debug_inspect(cfg_space.space, content="Some(\"s3\")")
  let cfg_space_id = NmemConfig::resolve(
    env_of([]),
    Some("{\"spaceId\": \"s4\"}"),
    source_app="cetas",
  )
  debug_inspect(cfg_space_id.space, content="Some(\"s4\")")
  let cfg_snake = NmemConfig::resolve(
    env_of([]),
    Some("{\"space_id\": \"s5\"}"),
    source_app="cetas",
  )
  debug_inspect(cfg_snake.space, content="Some(\"s5\")")
}

///|
test "resolve: agent ids chain env > camelCase > snake_case" {
  let agent = NmemConfig::resolve(
    env_of([("NMEM_AGENT_ID", "a-env")]),
    Some("{\"agentId\": \"a-camel\"}"),
    source_app="cetas",
  )
  debug_inspect(agent.agent_id, content="Some(\"a-env\")")
  let agent_camel = NmemConfig::resolve(
    env_of([]),
    Some("{\"agentId\": \"a-camel\"}"),
    source_app="cetas",
  )
  debug_inspect(agent_camel.agent_id, content="Some(\"a-camel\")")
  let agent_snake = NmemConfig::resolve(
    env_of([]),
    Some("{\"agent_id\": \"a-snake\"}"),
    source_app="cetas",
  )
  debug_inspect(agent_snake.agent_id, content="Some(\"a-snake\")")
  let host = NmemConfig::resolve(
    env_of([("NMEM_HOST_AGENT_ID", "h-env")]),
    Some("{\"hostAgentId\": \"h-camel\"}"),
    source_app="cetas",
  )
  debug_inspect(host.host_agent_id, content="Some(\"h-env\")")
  let host_camel = NmemConfig::resolve(
    env_of([]),
    Some("{\"hostAgentId\": \"h-camel\"}"),
    source_app="cetas",
  )
  debug_inspect(host_camel.host_agent_id, content="Some(\"h-camel\")")
  let host_snake = NmemConfig::resolve(
    env_of([]),
    Some("{\"host_agent_id\": \"h-snake\"}"),
    source_app="cetas",
  )
  debug_inspect(host_snake.host_agent_id, content="Some(\"h-snake\")")
}

///|
test "resolve: blank values are treated as missing at every level" {
  let config = NmemConfig::resolve(
    env_of([("NMEM_API_KEY", "  "), ("NMEM_PLUGIN_SOURCE_APP", "")]),
    Some("{\"apiUrl\": \"   \"}"),
    source_app="cetas",
  )
  inspect(config.api_url, content="http://127.0.0.1:14242")
  debug_inspect(config.api_key, content="None")
  inspect(config.source_app, content="cetas")
}

///|
test "resolve: malformed or non-object config text is ignored" {
  let broken = NmemConfig::resolve(
    env_of([]),
    Some("{ not json"),
    source_app="cetas",
  )
  inspect(broken.api_url, content="http://127.0.0.1:14242")
  let array_doc = NmemConfig::resolve(
    env_of([]),
    Some("[\"http://x\"]"),
    source_app="cetas",
  )
  inspect(array_doc.api_url, content="http://127.0.0.1:14242")
  let scalar_doc = NmemConfig::resolve(
    env_of([]),
    Some("\"hello\""),
    source_app="cetas",
  )
  inspect(scalar_doc.api_url, content="http://127.0.0.1:14242")
}

///|
test "resolve: non-string config entries are ignored" {
  let config = NmemConfig::resolve(
    env_of([]),
    Some("{\"apiUrl\": 42, \"space\": true}"),
    source_app="cetas",
  )
  inspect(config.api_url, content="http://127.0.0.1:14242")
  debug_inspect(config.space, content="None")
}

///|
test "resolve: source_app env override wins over the constructor parameter" {
  let config = NmemConfig::resolve(
    env_of([("NMEM_PLUGIN_SOURCE_APP", " demo ")]),
    None,
    source_app="cetas",
  )
  inspect(config.source_app, content="demo")
}
