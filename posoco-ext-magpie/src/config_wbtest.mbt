///|
/// config_wbtest.mbt — configuration validation, loopback detection, and
/// the credential boundary (scenarios: remote-without-credential,
/// explicit credential precedence, InvalidConfig shapes).

///|
test "default configuration uses the documented local gateway" {
  let config = local_config()
  inspect(config.base_url, content="http://127.0.0.1:3425")
  inspect(config.enabled, content="true")
  inspect(config.connect_timeout_ms, content="5000")
  debug_inspect(config.credential, content="None")
  // Loopback endpoint with no credential: the documented local app token.
  debug_inspect(effective_token(config), content="Some(\"magpie-posoco\")")
}

///|
test "base_url normalization and scheme validation" {
  inspect(
    must_config(() => {
      MagpieConfig::MagpieConfig(base_url="http://127.0.0.1:3425/")
    }).base_url,
    content="http://127.0.0.1:3425",
  )
  inspect(
    must_config(() => {
      MagpieConfig::MagpieConfig(base_url="https://magpie.example.com")
    }).base_url,
    content="https://magpie.example.com",
  )
  try MagpieConfig::MagpieConfig(base_url="ftp://magpie.example.com") catch {
    MagpieGatewayError::InvalidConfig(_) => ()
    _ => fail("expected InvalidConfig")
  } noraise {
    _ => fail("expected InvalidConfig")
  }
  try MagpieConfig::MagpieConfig(base_url="http://") catch {
    MagpieGatewayError::InvalidConfig(_) => ()
    _ => fail("expected InvalidConfig")
  } noraise {
    _ => fail("expected InvalidConfig")
  }
}

///|
test "non-positive timeout and effort-without-model are invalid" {
  try MagpieConfig::MagpieConfig(connect_timeout_ms=0) catch {
    MagpieGatewayError::InvalidConfig(_) => ()
    _ => fail("expected InvalidConfig")
  } noraise {
    _ => fail("expected InvalidConfig")
  }
  try MagpieConfig::MagpieConfig(selected_effort=Some("high")) catch {
    MagpieGatewayError::InvalidConfig(_) => ()
    _ => fail("expected InvalidConfig")
  } noraise {
    _ => fail("expected InvalidConfig")
  }
}

///|
test "explicit credential wins; remote endpoints get none without one" {
  let remote = "https://magpie.example.com"
  debug_inspect(
    effective_token(
      must_config(() => MagpieConfig::MagpieConfig(base_url=remote)),
    ),
    content="None",
  )
  debug_inspect(
    effective_token(
      must_config(() => {
        MagpieConfig::MagpieConfig(
          base_url=remote,
          credential=Some("sk-magpie-gateway"),
        )
      }),
    ),
    content="Some(\"sk-magpie-gateway\")",
  )
  // A configured credential is honored even on loopback.
  debug_inspect(
    effective_token(
      must_config(() => {
        MagpieConfig::MagpieConfig(credential=Some("sk-magpie-gateway"))
      }),
    ),
    content="Some(\"sk-magpie-gateway\")",
  )
}

///|
test "loopback detection covers the documented hosts and ports" {
  inspect(is_loopback_url("http://127.0.0.1:3425/api/hello"), content="true")
  inspect(is_loopback_url("http://localhost:3425/v1/models"), content="true")
  inspect(is_loopback_url("http://[::1]:3425/api/hello"), content="true")
  inspect(is_loopback_url("http://user@127.0.0.1:3425"), content="true")
  inspect(is_loopback_url("https://magpie.example.com"), content="false")
  inspect(is_loopback_url("http://192.168.1.20:3425"), content="false")
  inspect(is_loopback_url("not a url"), content="false")
}

///|
test "gateway urls append the path to the normalized base" {
  let config = must_config(() => {
    MagpieConfig::MagpieConfig(base_url="http://127.0.0.1:3425/")
  })
  inspect(
    gateway_url(config, "/api/hello"),
    content="http://127.0.0.1:3425/api/hello",
  )
  inspect(
    gateway_url(config, "/v1/models"),
    content="http://127.0.0.1:3425/v1/models",
  )
}
