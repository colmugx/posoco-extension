///|
/// manager_concurrency_wbtest.mbt — overlapping refresh safety
/// (scenario 22: concurrent or overlapping refresh).

///|
async test "overlapping refreshes serialize and commit atomically" {
  let catalog_a = models_body(
    "\{model_entry(id="a/one")},\{model_entry(id="a/two")}",
  )
  let catalog_b = models_body(model_entry(id="b/one"))
  let transport = FakeTransport([
    Respond(code=200, body=hello_body(version="1")),
    Respond(code=200, body=catalog_a),
    Respond(code=200, body=hello_body(version="2")),
    Respond(code=200, body=catalog_b),
  ])
  transport.delay_ms = 1
  let manager = manager_with(transport~, config=local_config())
  let first : Ref[MagpieRefreshOutcome?] = Ref(None)
  let second : Ref[MagpieRefreshOutcome?] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => first.val = Some(manager.refresh()))
    group.spawn_bg(() => second.val = Some(manager.refresh()))
  })
  // Both cycles completed with coherent reports: 2 models then 1 model,
  // in acquisition order.
  inspect(first.val.unwrap().total + second.val.unwrap().total, content="3")
  // The internal mutex serialized the cycles: hello, models, hello, models.
  inspect(
    transport.calls.join(" "),
    content=(
      #|http://127.0.0.1:3425/api/hello http://127.0.0.1:3425/v1/models http://127.0.0.1:3425/api/hello http://127.0.0.1:3425/v1/models
    ),
  )
  // The committed catalog is exactly one payload, never a mixture.
  let final_ids = ids(manager.list_models())
  inspect(final_ids.length(), content="1")
  inspect(final_ids[0] is "a/one" || final_ids[0] is "b/one", content="true")
  inspect(manager.connection_status().connected(), content="true")
}

///|
async test "a failing overlapping refresh leaves coherent state" {
  let catalog_a = models_body(model_entry(id="a/one"))
  let transport = FakeTransport([
    Respond(code=200, body=hello_body()),
    Respond(code=200, body=catalog_a),
    FailWith(MagpieGatewayError::Offline("gateway went away")),
  ])
  transport.delay_ms = 1
  let manager = manager_with(transport~, config=local_config())
  @async.with_task_group(group => {
    group.spawn_bg(allow_failure=true, () => {
      let _ = manager.refresh()
    })
    group.spawn_bg(allow_failure=true, () => {
      let _ = manager.refresh()
    })
  })
  // Exactly one cycle can have succeeded: the committed catalog and the
  // success report must match it exactly, never a half-updated mixture.
  // The status names whichever attempt acquired the lock last — the
  // failure's Offline or the success's Connected — and both keep the
  // catalog coherent.
  let report = manager.last_refresh_report()
  guard report is Some(outcome) else {
    fail("the successful cycle must leave its report")
  }
  inspect(outcome.total, content="1")
  debug_inspect(ids(manager.list_models()), content="[\"a/one\"]")
  let status = manager.connection_status()
  guard status is Offline(_) || status.connected() else {
    fail("status must reflect one of the two attempts")
  }
}
