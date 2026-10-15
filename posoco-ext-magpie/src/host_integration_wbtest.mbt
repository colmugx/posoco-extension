///|
/// host_integration_wbtest.mbt — Host-level acceptance tests.
///
/// Everything here composes the extension the way a real Host does:
/// `Agent::Agent(exts~, config~)`, then drives it through the Agent's own
/// command surface. Deterministic scripted transports only; no network.

///|
/// Invoke a magpie command through the composed Agent's own command
/// surface, exactly as a Host would.
async fn host_invoke(
  agent : @posoco.Agent,
  id~ : String,
  args~ : Json,
) -> @posoco.CommandOutcome raise {
  for port in agent.commands() {
    for def in port.commands() {
      if def.id == id {
        return port.invoke(id, args)
      }
    }
  }
  fail("composed agent does not expose command \{id}")
}

///|
/// All command ids declared through the composed agent.
fn composed_command_ids(agent : @posoco.Agent) -> Array[String] {
  let ids : Array[String] = []
  for port in agent.commands() {
    for def in port.commands() {
      ids.push(def.id)
    }
  }
  ids
}

///|
async test "host composition discovers the extension, its model port and command surface" {
  let runtime = MagpieRuntime::activate(
    transport=FakeTransport([
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ]),
  )
  let agent = @posoco.Agent::Agent(
    exts=[runtime],
    config=@posoco.tk_config(),
  )
  let ids = composed_command_ids(agent)
  for expected in [
    "magpie_model", "magpie_status", "magpie_refresh", "magpie_route",
    "magpie_quotas", "magpie_limit", "magpie_usage", "magpie_requests",
    "magpie_concurrency", "magpie_usage_recent",
  ] {
    guard ids.contains(expected) else {
      fail("composed agent is missing command \{expected}")
    }
  }
  // The manifest contributes exactly one model port (host cardinality = 1).
  inspect(runtime.manifest().models.length(), content="1")
}

///|
async test "first turn flows through the composed model port with selection" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[buffered_post(status=200, body=messages_nonstream_body(text="hi there"))],
  )
  let runtime = MagpieRuntime::activate(transport~)
  let agent = @posoco.Agent::Agent(
    exts=[runtime],
    config=@posoco.tk_config(),
  )
  // Host startup loads the catalog before selection is possible.
  runtime.on_start()
  // Model selection through the composed command surface.
  guard
    host_invoke(
      agent,
      id="magpie_model",
      args=Json::object({ "model": Json::string("anthropic/claude-native") }),
    ) is @posoco.CommandOutcome::Success(..) else {
    fail("model selection through the composed agent failed")
  }
  // A real turn: the Host-visible lifecycle fires on_start (catalog
  // refresh), then the composed ModelPort executes against the gateway.
  let result = agent.run_turn(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hello")]),
    "host-session-1",
  )
  let mut text = ""
  guard
    result.message
    is @posoco.Message::AssistantMessage(content=completion, ..) else {
    fail("turn must end with an assistant message")
  }
  for block in completion {
    guard block is @posoco.Content::Text(part) else { continue }
    text = text + part
  }
  inspect(text, content="hi there")
  // The POST went through the extension's transport with the session header.
  inspect(transport.post_calls.length() > 0, content="true")
  inspect(
    transport.post_sessions[0].contains("host-session-1"),
    content="true",
  )
}

///|
async test "duplicate extension registration is rejected by composition" {
  let runtime = MagpieRuntime::activate(
    transport=FakeTransport([
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ]),
  )
  // The same instance twice would double-register commands and the model
  // slot; composition must refuse rather than silently merge.
  try
    @posoco.Agent::Agent(
      exts=[runtime, runtime],
      config=@posoco.tk_config(),
    ) catch {
      _ => ()
    } noraise {
      _ => fail("duplicate extension registration must be rejected")
    }
}

///|
async test "two model managers cannot share one agent; separate agents keep selection isolated" {
  let runtime_a = MagpieRuntime::activate(
    transport=FakeTransport([
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ]),
  )
  let runtime_b = MagpieRuntime::activate(
    transport=FakeTransport([
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ]),
  )
  // Both declare a ModelPort; the single model slot makes co-registration a
  // composition error, not a silent override.
  try
    @posoco.Agent::Agent(
      exts=[runtime_a, runtime_b],
      config=@posoco.tk_config(),
    ) catch {
      _ => ()
    } noraise {
      _ => fail("two model managers must not compose into one agent")
    }
  // Coexistence is per-agent: independent runtimes hold independent
  // selection state (no global registry).
  let _ = runtime_a.manager.refresh()
  let _ = runtime_b.manager.refresh()
  let _ = runtime_a.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let _ = runtime_b.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("openai/gpt-chat") }),
  )
  inspect(
    runtime_a.manager.active_selection().model_id,
    content="anthropic/claude-native",
  )
  inspect(
    runtime_b.manager.active_selection().model_id,
    content="openai/gpt-chat",
  )
}

///|
async test "invalid configuration starts degraded, never silently on the default gateway" {
  let runtime = MagpieRuntime::activate(
    settings=Some(
      Json::object({ "enabled": Json::string("yes") }),
    ),
    transport=FakeTransport([
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ]),
  )
  guard runtime.unconfigured_reason() is Some(_) else {
    fail("invalid settings must record the reason")
  }
  let agent = @posoco.Agent::Agent(
    exts=[runtime],
    config=@posoco.tk_config(),
  )
  guard
    host_invoke(agent, id="magpie_status", args=Json::null())
    is @posoco.CommandOutcome::Success(structured=Some(status), ..) else {
    fail("status must answer after degraded startup")
  }
  // The degraded runtime records the reason, holds no selection, and has
  // loaded nothing — the default gateway is never silently activated.
  guard status is Json::Object(fields) else { fail("status must be an object") }
  guard fields.get("unconfigured_reason") is Some(Json::String(_)) else {
    fail("degraded startup must surface the recorded reason")
  }
  guard fields.get("selected") is Some(Json::String("")) else {
    fail("degraded startup must not hold a model selection")
  }
  guard fields.get("catalog_size") is Some(Json::Number(n, ..)) && n.to_int() == 0 else {
    fail("degraded startup must not load a catalog")
  }
}

///|
async test "offline gateway does not crash host startup and recovers on reconnect" {
  let transport = FakeTransport([
    FailWith(MagpieGatewayError::Offline("connection refused")),
    Respond(code=200, body=hello_body()),
    Respond(code=200, body=exec_catalog_body()),
  ])
  let runtime = MagpieRuntime::activate(transport~)
  let agent = @posoco.Agent::Agent(
    exts=[runtime],
    config=@posoco.tk_config(),
  )
  // Host startup: on_start must swallow the offline gateway.
  runtime.on_start()
  guard
    host_invoke(agent, id="magpie_status", args=Json::null())
    is @posoco.CommandOutcome::Success(structured=Some(offline), ..) else {
    fail("status must answer while offline")
  }
  guard offline is Json::Object(offline_fields) else {
    fail("status must be an object")
  }
  guard offline_fields.get("connected") is Some(Json::False) else {
    fail("offline startup must report a disconnected gateway")
  }
  // Recovery: the next lifecycle start refreshes successfully.
  runtime.on_start()
  guard
    host_invoke(agent, id="magpie_status", args=Json::null())
    is @posoco.CommandOutcome::Success(structured=Some(recovered), ..) else {
    fail("status must answer after recovery")
  }
  guard recovered is Json::Object(recovered_fields) else {
    fail("status must be an object")
  }
  guard recovered_fields.get("connected") is Some(Json::True) else {
    fail("recovery must report a connected gateway")
  }
  guard
    recovered_fields.get("catalog_size")
    is Some(Json::Number(size, ..)) && size.to_int() > 0 else {
    fail("recovery must load the catalog")
  }
}

///|
async test "repeated lifecycle transitions keep the command surface consistent" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[buffered_post(status=200, body=messages_nonstream_body(text="ok"))],
  )
  let runtime = MagpieRuntime::activate(transport~)
  let agent = @posoco.Agent::Agent(
    exts=[runtime],
    config=@posoco.tk_config(),
  )
  runtime.on_start()
  runtime.on_shutdown()
  // After shutdown the command surface must refuse work, not serve stale state.
  try host_invoke(agent, id="magpie_status", args=Json::null()) catch {
    _ => ()
  } noraise {
    _ => fail("commands must be rejected after shutdown")
  }
  // Reactivation restores full service without duplicate registrations.
  runtime.on_start()
  guard
    host_invoke(agent, id="magpie_status", args=Json::null())
    is @posoco.CommandOutcome::Success(..) else {
    fail("commands must work again after reactivation")
  }
  inspect(composed_command_ids(agent).length() >= 10, content="true")
}

///|
async test "shutdown drops owned observation state; reactivation rebuilds it" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[buffered_post(status=200, body=messages_nonstream_body(text="done"))],
  )
  let runtime = MagpieRuntime::activate(transport~)
  let agent = @posoco.Agent::Agent(
    exts=[runtime],
    config=@posoco.tk_config(),
  )
  runtime.on_start()
  let _ = host_invoke(
    agent,
    id="magpie_model",
    args=Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let _ = agent.run_turn(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("go")]),
    "host-session-2",
  )
  inspect(runtime.recent_reports().length() > 0, content="true")
  runtime.on_shutdown()
  inspect(runtime.recent_reports().length(), content="0")
}
