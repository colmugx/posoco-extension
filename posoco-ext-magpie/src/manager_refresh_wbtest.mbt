///|
/// manager_refresh_wbtest.mbt — refresh lifecycle
/// (scenarios 2: offline, 4: auth failure, 5: valid models, 6: empty
/// catalog, 19: refresh failure preserves state, plus enable/disable and
/// the remote credential boundary).

///|
async test "refresh validates identity then loads the catalog" {
  let transport = gateway(
    models=models_body(
      "\{model_entry(id="deepseek/deepseek-v4-pro")},\{model_entry(id="group/auto-gpt-6-luna", owned_by="codex")}",
    ),
  )
  let manager = manager_with(transport~, config=local_config())
  inspect(manager.connection_status(), content="NotConfigured")
  let outcome = manager.refresh()
  inspect(outcome.total, content="2")
  inspect(outcome.added, content="2")
  inspect(outcome.removed, content="0")
  debug_inspect(outcome.duplicates, content="[]")
  // Both endpoints hit, in documented order, with the local app token.
  debug_inspect(
    transport.calls,
    content="[\"http://127.0.0.1:3425/api/hello\", \"http://127.0.0.1:3425/v1/models\"]",
  )
  inspect(transport.auths[0], content="Bearer magpie-posoco")
  inspect(transport.auths[1], content="Bearer magpie-posoco")
  guard manager.connection_status() is Connected(Some(version)) else {
    fail("expected Connected with a version")
  }
  inspect(version, content="0.1.1224")
  debug_inspect(
    ids(manager.list_models()),
    content="[\"deepseek/deepseek-v4-pro\", \"group/auto-gpt-6-luna\"]",
  )
}

///|
async test "offline gateway leaves the status honest" {
  let transport = FakeTransport([
    FailWith(MagpieGatewayError::Offline("connection refused")),
  ])
  let manager = manager_with(transport~, config=local_config())
  try manager.refresh() catch {
    MagpieGatewayError::Offline(detail) =>
      inspect(detail.contains("connection refused"), content="true")
    _ => fail("expected Offline")
  } noraise {
    _ => fail("expected Offline")
  }
  guard manager.connection_status() is Offline(detail) else {
    fail("expected Offline status")
  }
  inspect(detail.contains("connection refused"), content="true")
  inspect(manager.list_models().length(), content="0")
}

///|
async test "authentication failure is distinguished from other errors" {
  let manager = manager_with(
    transport=FakeTransport([Respond(code=401, body="{\"error\":\"bad key\"}")]),
    config=local_config(),
  )
  try manager.refresh() catch {
    MagpieGatewayError::AuthenticationFailed(detail) =>
      inspect(detail.contains("401"), content="true")
    _ => fail("expected AuthenticationFailed")
  } noraise {
    _ => fail("expected AuthenticationFailed")
  }
  guard manager.connection_status() is AuthFailed(_) else {
    fail("expected AuthFailed status")
  }
  // 403 on the models endpoint, after a valid hello.
  let manager2 = manager_with(
    transport=FakeTransport([
      Respond(code=200, body=hello_body()),
      Respond(code=403, body="{\"error\":\"denied\"}"),
    ]),
    config=local_config(),
  )
  try manager2.refresh() catch {
    MagpieGatewayError::AuthenticationFailed(_) => ()
    _ => fail("expected AuthenticationFailed")
  } noraise {
    _ => fail("expected AuthenticationFailed")
  }
  inspect(
    manager2.connection_status().describe().contains("authentication failed"),
    content="true",
  )
}

///|
async test "empty catalog is a connected state of its own" {
  let manager = manager_with(
    transport=gateway(models="{\"data\":[]}"),
    config=local_config(),
  )
  let outcome = manager.refresh()
  inspect(outcome.total, content="0")
  inspect(manager.connection_status(), content="EmptyCatalog")
  inspect(manager.connection_status().connected(), content="true")
  inspect(manager.list_models().length(), content="0")
}

///|
async test "a failed refresh preserves last-known-good state" {
  let good = models_body(model_entry(id="deepseek/deepseek-v4-pro"))
  let transport = FakeTransport([
    Respond(code=200, body=hello_body()),
    Respond(code=200, body=good),
    FailWith(MagpieGatewayError::Offline("gateway went away")),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let control = manager as &@modelmgmt.ModelManagerControl
  control.select_model("deepseek/deepseek-v4-pro")
  control.select_effort("high")
  // The failed refresh must not touch catalog or selection.
  try manager.refresh() catch {
    MagpieGatewayError::Offline(_) => ()
    _ => fail("expected Offline")
  } noraise {
    _ => fail("expected Offline")
  }
  debug_inspect(
    ids(manager.list_models()),
    content="[\"deepseek/deepseek-v4-pro\"]",
  )
  inspect(
    selection_text(manager),
    content="deepseek/deepseek-v4-pro/high/pending=false",
  )
  guard manager.connection_status() is Offline(_) else {
    fail("expected Offline status")
  }
  // The successful report from before the failure survives.
  inspect(manager.last_refresh_report().unwrap().total, content="1")
}

///|
async test "disabled managers never touch the network" {
  let transport = FakeTransport([])
  let config = MagpieConfig::MagpieConfig(enabled=false) catch {
    _ => fail("disabled config must be valid")
  }
  let manager = manager_with(transport~, config~)
  try manager.refresh() catch {
    MagpieGatewayError::Disabled => ()
    _ => fail("expected Disabled")
  } noraise {
    _ => fail("expected Disabled")
  }
  inspect(manager.connection_status(), content="Disabled")
  inspect(transport.calls.length(), content="0")
}

///|
async test "remote gateway without a configured credential is NotConfigured" {
  let transport = FakeTransport([])
  let config = MagpieConfig::MagpieConfig(base_url="https://magpie.example.com") catch {
    _ => fail("remote config must be valid")
  }
  let manager = manager_with(transport~, config~)
  try manager.refresh() catch {
    MagpieGatewayError::NotConfigured(_) => ()
    _ => fail("expected NotConfigured")
  } noraise {
    _ => fail("expected NotConfigured")
  }
  inspect(manager.connection_status(), content="NotConfigured")
  // The local application token was never sent to the remote endpoint.
  inspect(transport.calls.length(), content="0")
}

///|
async test "wrong identity and malformed payloads surface as InvalidGateway" {
  let wrong = manager_with(
    transport=gateway(
      models="{}",
      hello="{\"name\":\"other-gateway\",\"version\":\"9\"}",
    ),
    config=local_config(),
  )
  try wrong.refresh() catch {
    MagpieGatewayError::WrongIdentity(_) => ()
    _ => fail("expected WrongIdentity")
  } noraise {
    _ => fail("expected WrongIdentity")
  }
  guard wrong.connection_status() is InvalidGateway(_) else {
    fail("expected InvalidGateway status")
  }
  let malformed = manager_with(
    transport=gateway(models="{\"data\":[{\"oops\":1}]}"),
    config=local_config(),
  )
  try malformed.refresh() catch {
    MagpieGatewayError::InvalidResponse(_) => ()
    _ => fail("expected InvalidResponse")
  } noraise {
    _ => fail("expected InvalidResponse")
  }
  guard malformed.connection_status() is InvalidGateway(_) else {
    fail("expected InvalidGateway status")
  }
}

///|
async test "a refresh swap reports added, removed and duplicates" {
  let first = models_body(
    "\{model_entry(id="a/one")},\{model_entry(id="b/two")}",
  )
  let second = models_body(
    "\{model_entry(id="b/two")},\{model_entry(id="b/two")},\{model_entry(id="c/three")}",
  )
  let transport = FakeTransport([
    Respond(code=200, body=hello_body()),
    Respond(code=200, body=first),
    Respond(code=200, body=hello_body()),
    Respond(code=200, body=second),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let outcome = manager.refresh()
  inspect(outcome.total, content="2")
  inspect(outcome.added, content="1")
  inspect(outcome.removed, content="1")
  debug_inspect(outcome.duplicates, content="[\"b/two\"]")
}
