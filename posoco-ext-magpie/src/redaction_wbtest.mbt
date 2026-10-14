///|
/// redaction_wbtest.mbt — credential hygiene (scenario 21: credential
/// redaction). The credential may exist in exactly one place — the
/// Authorization header built per request — and must appear nowhere else:
/// not in debug renders, not in status text, not in errors, even when a
/// hostile endpoint echoes it back.

///|
async test "configuration renders the credential only as <redacted>" {
  let secret = "sk-magpie-super-secret-value"
  let config = MagpieConfig::MagpieConfig(credential=Some(secret)) catch {
    _ => fail("credential config must be valid")
  }
  let rendered = @debug.to_string(config)
  inspect(rendered.contains("<redacted>"), content="true")
  inspect(rendered.contains(secret), content="false")
  let shown = config.to_string()
  inspect(shown.contains("<redacted>"), content="true")
  inspect(shown.contains(secret), content="false")
  // Without a credential nothing pretends to have one.
  let bare = local_config()
  inspect(@debug.to_string(bare).contains("\"<redacted>\""), content="false")
}

///|
async test "status text never carries the credential" {
  let secret = "sk-magpie-super-secret-value"
  let config = MagpieConfig::MagpieConfig(credential=Some(secret)) catch {
    _ => fail("credential config must be valid")
  }
  let transport = gateway(models="{\"data\":[]}")
  let manager = manager_with(transport~, config~)
  refresh_ok(manager)
  let described = manager.connection_status().describe()
  inspect(described.contains(secret), content="false")
  // The header itself must still carry the configured credential.
  inspect(transport.auths[0], content="Bearer \{secret}")
}

///|
async test "errors never quote bodies, even echoing endpoints" {
  let secret = "sk-magpie-super-secret-value"
  // A hostile gateway echoes the presented credential in an error body.
  let transport = FakeTransport([
    Respond(
      code=500,
      body="{\"error\":\"Authorization: Bearer \{secret} rejected\"}",
    ),
    FailWith(MagpieGatewayError::Offline("boom")),
    Respond(code=200, body=hello_body()),
    Respond(code=200, body="{\"data\":[{\"secret\":\"\{secret}\"}]}"),
  ])
  let manager = manager_with(transport~, config=local_config())
  try manager.refresh() catch {
    error => {
      let text = error.to_string()
      inspect(text.contains("500"), content="true")
      inspect(text.contains(secret), content="false")
    }
  } noraise {
    _ => fail("expected InvalidResponse")
  }
  // Offline errors originate locally and stay structural too.
  try manager.refresh() catch {
    error => inspect(error.to_string().contains("boom"), content="true")
  } noraise {
    _ => fail("expected Offline")
  }
  // Malformed success bodies never leak into errors either.
  try manager.refresh() catch {
    error => inspect(error.to_string().contains(secret), content="false")
  } noraise {
    _ => fail("expected InvalidResponse")
  }
}
