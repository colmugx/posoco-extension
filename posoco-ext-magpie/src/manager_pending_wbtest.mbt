///|
/// manager_pending_wbtest.mbt — persisted selections and pending semantics
/// (scenarios 16–18: persisted pending model, pending becoming available,
/// model disappearing after refresh).

///|
async test "a persisted selection absent from the catalog reports pending" {
  let config = MagpieConfig::MagpieConfig(
    selected_model=Some("group/never-stuck"),
    selected_effort=Some("high"),
  ) catch {
    _ => fail("seeded config must be valid")
  }
  let manager = manager_with(
    transport=gateway(
      models=models_body(model_entry(id="deepseek/deepseek-v4-pro")),
    ),
    config~,
  )
  // Before any refresh nothing is known; the seed must not be rewritten.
  inspect(
    selection_text(manager),
    content="group/never-stuck/high/pending=true",
  )
  refresh_ok(manager)
  // Connected, but the seeded model is still not in this catalog.
  inspect(
    selection_text(manager),
    content="group/never-stuck/high/pending=true",
  )
  debug_inspect(
    ids(manager.list_models()),
    content="[\"deepseek/deepseek-v4-pro\"]",
  )
}

///|
async test "a pending model becomes available when a refresh exposes it" {
  let config = MagpieConfig::MagpieConfig(
    selected_model=Some("group/never-stuck"),
    selected_effort=Some("high"),
  ) catch {
    _ => fail("seeded config must be valid")
  }
  let transport = FakeTransport([
    Respond(code=200, body=hello_body()),
    Respond(code=200, body=models_body("")),
    Respond(code=200, body=hello_body()),
    Respond(
      code=200,
      body=models_body(model_entry(id="group/never-stuck", owned_by="codex")),
    ),
  ])
  let manager = manager_with(transport~, config~)
  refresh_ok(manager)
  inspect(manager.connection_status(), content="EmptyCatalog")
  inspect(
    selection_text(manager),
    content="group/never-stuck/high/pending=true",
  )
  // The gateway now exposes the routing group.
  refresh_ok(manager)
  inspect(
    selection_text(manager),
    content="group/never-stuck/high/pending=false",
  )
  // The seeded effort survives; refresh never rewrites selection.
  debug_inspect(manager.active_selection().effort, content="Some(\"high\")")
}

///|
async test "a selected model disappearing after refresh goes pending, not rewritten" {
  let manager = manager_with(
    transport=FakeTransport([
      Respond(code=200, body=hello_body()),
      Respond(
        code=200,
        body=models_body(
          "\{model_entry(id="a/one")},\{model_entry(id="b/two")}",
        ),
      ),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=models_body(model_entry(id="b/two"))),
    ]),
    config=local_config(),
  )
  refresh_ok(manager)
  let control = manager as &@modelmgmt.ModelManagerControl
  control.select_model("a/one")
  control.select_effort("medium")
  inspect(selection_text(manager), content="a/one/medium/pending=false")
  // The gateway stopped exposing a/one.
  refresh_ok(manager)
  inspect(selection_text(manager), content="a/one/medium/pending=true")
  debug_inspect(ids(manager.list_models()), content="[\"b/two\"]")
  // The active selection is still untouchable for efforts while pending.
  try control.select_effort("high") catch {
    @modelmgmt.ModelManagerError::UnknownModel(_) => ()
    _ => fail("expected UnknownModel")
  } noraise {
    _ => fail("expected UnknownModel")
  }
  inspect(selection_text(manager), content="a/one/medium/pending=true")
}

///|
async test "refresh never silently selects a different model" {
  let config = MagpieConfig::MagpieConfig(selected_model=Some("a/one")) catch {
    _ => fail("seeded config must be valid")
  }
  let transport = FakeTransport([
    Respond(code=200, body=hello_body()),
    Respond(code=200, body=models_body(model_entry(id="b/two"))),
  ])
  let manager = manager_with(transport~, config~)
  refresh_ok(manager)
  // b/two is the only model, but the persisted a/one stays reported.
  inspect(selection_text(manager), content="a/one/-/pending=true")
  debug_inspect(ids(manager.list_models()), content="[\"b/two\"]")
}
