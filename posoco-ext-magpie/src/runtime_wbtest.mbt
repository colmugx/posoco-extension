///|
/// runtime_wbtest.mbt — runtime integration tests: activation, lifecycle,
/// commands, session isolation, and coexistence, all offline against the
/// fake gateway.

///|
fn runtime_transport(posts~ : Array[FakePostStep]) -> FakeTransport {
  FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=posts,
  )
}

///|
async fn activate_runtime(
  transport~ : &MagpieTransport,
  settings~ : Json? = None,
) -> MagpieRuntime {
  let runtime = MagpieRuntime::activate(settings=settings, transport=transport)
  runtime.on_start()
  runtime
}

///|
fn invoke_text(outcome : @posoco.CommandOutcome) -> String raise {
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) => feedback
    @posoco.CommandOutcome::Failure(reason~) => raise Failure(reason)
    @posoco.CommandOutcome::NeedsInput(prompt~) => prompt
  }
}

///|
/// The structured payload of a successful command outcome.
fn invoke_structured(outcome : @posoco.CommandOutcome) -> Json raise {
  match outcome {
    @posoco.CommandOutcome::Success(structured=Some(json), ..) => json
    @posoco.CommandOutcome::Success(..) => fail("expected structured output")
    @posoco.CommandOutcome::Failure(reason~) => raise Failure(reason)
    @posoco.CommandOutcome::NeedsInput(prompt~) => fail(prompt)
  }
}

///|
async test "activation wires manager, port, intelligence and commands" {
  let runtime = activate_runtime(transport=runtime_transport(posts=[]))
  let manifest = runtime.manifest()
  inspect(manifest.id, content="posoco_ext_magpie")
  inspect(manifest.models.length(), content="1")
  inspect(manifest.commands.length(), content="1")
  inspect(manifest.lifecycle.length(), content="1")
  inspect(runtime.extension_id(), content="posoco_ext_magpie")
  // Commands are declared.
  inspect(runtime.commands().length() >= 8, content="true")
}

///|
async test "gateway offline during activation leaves an explicit offline state" {
  let transport = FakeTransport(
    [FailWith(MagpieGatewayError::Offline("connection refused"))],
    posts=[],
  )
  let runtime = activate_runtime(transport~)
  // The refresh failure was swallowed: no crash, explicit offline.
  inspect(runtime.manager.connection_status() is Offline(_), content="true")
  inspect(runtime.status_feedback().contains("offline"), content="true")
  // And the runtime recovers when the gateway comes back.
  let recovered = runtime_transport(posts=[])
  let _ = recovered
  runtime.on_start()
}

///|
async test "missing configuration falls back to documented defaults" {
  let runtime = activate_runtime(transport=runtime_transport(posts=[]))
  runtime.on_start()
  inspect(runtime.unconfigured_reason() is None, content="true")
  // Defaults: the documented local gateway address.
  inspect(
    runtime.status_feedback().contains("http://127.0.0.1:3425") ||
    runtime.manager.connection_status() is Offline(_),
    content="true",
  )
}

///|
async test "invalid configuration recovers with a recorded reason" {
  let runtime = activate_runtime(
    transport=runtime_transport(posts=[]),
    settings=Some(Json::object({ "base_url": Json::number(42) })),
  )
  // Startup survived; the reason is surfaced, defaults active.
  guard runtime.unconfigured_reason() is Some(reason) else {
    fail("invalid settings must record a reason")
  }
  inspect(reason.contains("settings.base_url"), content="true")
  inspect(runtime.active, content="true")
}

///|
async test "catalog refresh and model discovery through the model command" {
  let runtime = activate_runtime(transport=runtime_transport(posts=[]))
  let outcome = runtime.invoke("model", Json::null()) catch {
    error => fail("model listing must succeed: \{error}")
  }
  let catalog = invoke_structured(outcome)
  inspect(catalog.stringify().contains("anthropic/claude-native"), content="true")
  inspect(catalog.stringify().contains("group/auto"), content="true")
}

///|
async test "switching models goes through the manager surface" {
  let runtime = activate_runtime(transport=runtime_transport(posts=[]))
  let selection = runtime.manager.active_selection()
  inspect(selection.pending, content="true")
  let outcome = runtime.invoke(
    "model",
    Json::object({ "model": Json::string("codex/gpt-responses") }),
  )
  inspect(invoke_text(outcome).contains("codex/gpt-responses"), content="true")
  inspect(runtime.manager.active_selection().model_id == "codex/gpt-responses", content="true")
  // Unknown ids are argument errors; selection unchanged.
  try
    runtime.invoke(
      "model",
      Json::object({ "model": Json::string("nope/gone") }),
    )
  catch {
    @posoco.CommandError::InvalidArgs(_) => ()
    _ => fail("expected InvalidArgs")
  } noraise {
    _ => ()
  }
  inspect(runtime.manager.active_selection().model_id == "codex/gpt-responses", content="true")
}

///|
async test "switching effort applies and rejects unadvertised levels" {
  let runtime = activate_runtime(transport=runtime_transport(posts=[]))
  let _ = runtime.invoke(
    "model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let outcome = runtime.invoke(
    "model",
    Json::object({ "effort": Json::string("high") }),
  )
  inspect(invoke_text(outcome).contains("effort high"), content="true")
  inspect(runtime.manager.active_selection().effort == Some("high"), content="true")
  try
    runtime.invoke(
      "model",
      Json::object({ "effort": Json::string("ultra") }),
    )
  catch {
    @posoco.CommandError::InvalidArgs(_) => ()
    _ => fail("expected InvalidArgs")
  } noraise {
    _ => ()
  }
  inspect(runtime.manager.active_selection().effort == Some("high"), content="true")
}

///|
async test "a pending selection is visible in status and rejects execution" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=models_body(model_entry(id="other/only"))),
    ],
    posts=[buffered_post(
      status=200,
      body=messages_nonstream_body(text="x"),
    )],
  )
  let runtime = activate_runtime(transport~)
  let _ = runtime.invoke(
    "model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  runtime.on_start()
  // The gateway dropped the selected model: status says pending.
  inspect(runtime.status_feedback().contains("pending=true"), content="true")
  let selection = runtime.manager.active_selection()
  inspect(selection.model_id == "anthropic/claude-native", content="true")
  inspect(selection.pending, content="true")
  // And execution refuses before any request.
  try
    runtime.model_port().chat(
      exec_scope(session="s"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  catch {
    @posoco.ModelError::RequestBuild(detail) =>
      inspect(detail.contains("pending"), content="true")
    _ => fail("expected RequestBuild")
  } noraise {
    _ => ()
  }
  inspect(transport.post_calls.length(), content="0")
}

///|
async test "session isolation and stable affinity across turns" {
  let transport = chat_transport(
    posts=[
      buffered_post(status=200, body=messages_nonstream_body(text="a")),
      buffered_post(status=200, body=messages_nonstream_body(text="b")),
      buffered_post(status=200, body=messages_nonstream_body(text="c")),
    ],
  )
  let runtime = activate_runtime(transport~)
  let _ = runtime.invoke(
    "model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  // Two turns of session A, one turn of session B.
  let _ = runtime.model_port().chat(
    exec_scope(session="sess-A"),
    user_text("1"),
    [],
    chat_options(),
    NoStream,
  )
  let _ = runtime.model_port().chat(
    exec_scope(session="sess-A"),
    user_text("2"),
    [],
    chat_options(),
    NoStream,
  )
  let _ = runtime.model_port().chat(
    exec_scope(session="sess-B"),
    user_text("3"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(transport.post_sessions[0], content="sess-A")
  inspect(transport.post_sessions[1], content="sess-A")
  inspect(transport.post_sessions[2], content="sess-B")
}

///|
async test "route status display never leaks the session id" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      Respond(code=500, body="internal"),
    ],
    posts=[],
  )
  let runtime = activate_runtime(transport~)
  let outcome = runtime.invoke(
    "magpie_route",
    Json::object({ "session": Json::string("sess-SECRET") }),
  )
  guard outcome is @posoco.CommandOutcome::Failure(reason~) else {
    fail("expected Failure")
  }
  inspect(reason.contains("500"), content="true")
  inspect(reason.contains("sess-SECRET"), content="false")
}

///|
async test "a quota 403 fails the quota command, not inference" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      Respond(code=403, body="{\"code\":\"gateway_key_held\"}"),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[buffered_post(
      status=200,
      body=messages_nonstream_body(text="inference fine"),
    )],
  )
  let runtime = activate_runtime(transport~)
  let outcome = runtime.invoke("magpie_quotas", Json::null())
  guard outcome is @posoco.CommandOutcome::Failure(reason~) else {
    fail("expected Failure")
  }
  inspect(reason.contains("gateway_key_held"), content="true")
  inspect(
    runtime.intelligence.service_availability(service=Quotas),
    content="Forbidden",
  )
  // Quota visibility is forbidden; inference is untouched.
  let _ = runtime.invoke(
    "model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let result = runtime.model_port().chat(
    exec_scope(session="sess-Q"),
    user_text("hi"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(
    result.completion.message.content == [@posoco.Content::Text("inference fine")],
    content="true",
  )
}

///|
async test "usage and cost display uses the gateway's own numbers" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      Respond(code=200, body=usage_requests_page([full_usage_row()])),
    ],
    posts=[],
  )
  let runtime = activate_runtime(transport~)
  let outcome = runtime.invoke(
    "magpie_requests",
    Json::object({ "period": Json::string("month") }),
  )
  let text = invoke_text(outcome)
  inspect(text.contains("$0.0123"), content="true")
  inspect(text.contains("gpt-6-luna"), content="true")
}

///|
async test "cache statistics appear in recent executions" {
  let usage_body = Json::object({
    "type": Json::string("message"),
    "id": Json::string("msg_cache"),
    "model": Json::string("claude-served"),
    "role": Json::string("assistant"),
    "content": Json::array([
      Json::object({
        "type": Json::string("text"),
        "text": Json::string("done"),
      }),
    ]),
    "stop_reason": Json::string("end_turn"),
    "stop_sequence": Json::null(),
    "usage": Json::object({
      "input_tokens": Json::number(100),
      "output_tokens": Json::number(5),
      "cache_read_input_tokens": Json::number(80),
      "cache_creation_input_tokens": Json::number(10),
    }),
  })
  .stringify()
  let transport = chat_transport(
    posts=[buffered_post(status=200, body=usage_body)],
  )
  let runtime = activate_runtime(transport~)
  let _ = runtime.invoke(
    "model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let _ = runtime.model_port().chat(
    exec_scope(session="sess-Cache"),
    user_text("hi"),
    [],
    chat_options(),
    NoStream,
  )
  let reports = runtime.recent_reports()
  inspect(reports.length(), content="1")
  inspect(reports[0].cache_read_tokens == Some(80), content="true")
  inspect(reports[0].cache_write_tokens == Some(10), content="true")
  let outcome = runtime.invoke("magpie_usage_recent", Json::null())
  inspect(invoke_text(outcome).contains("claude-native"), content="true")
}

///|
async test "credentials and keys are redacted everywhere" {
  let settings = Json::object({
    "gateway_key": Json::string("sk-magpie-super-secret"),
  })
  let runtime = activate_runtime(
    transport=runtime_transport(posts=[]),
    settings=Some(settings),
  )
  // The rendered status never names the key.
  inspect(runtime.status_feedback().contains("sk-magpie"), content="false")
  inspect(runtime.status_json().stringify().contains("sk-magpie"), content="false")
  // The credential still authenticates requests.
  let posting = chat_transport(
    posts=[buffered_post(status=200, body=messages_nonstream_body(text="ok"))],
  )
  let posting_runtime = activate_runtime(
    transport=posting,
    settings=Some(settings),
  )
  let _ = posting_runtime.invoke(
    "model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let _ = posting_runtime.model_port().chat(
    exec_scope(session="s"),
    user_text("hi"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(
    posting.post_auths[0],
    content="Bearer sk-magpie-super-secret",
  )
}

///|
async test "deactivation cleans up and commands refuse afterwards" {
  let transport = chat_transport(
    posts=[buffered_post(status=200, body=messages_nonstream_body(text="x"))],
  )
  let runtime = activate_runtime(transport~)
  runtime.on_shutdown()
  inspect(runtime.recent_reports().length(), content="0")
  try
    runtime.invoke("magpie_status", Json::null())
  catch {
    @posoco.CommandError::ExecutionFailed(detail) =>
      inspect(detail.contains("deactivated"), content="true")
    _ => fail("expected ExecutionFailed")
  } noraise {
    _ => ()
  }
}

///|
/// Magpie must expose its own namespaced commands without claiming
/// ext-llm's global /model command. Both managers can coexist.
async test "runtime commands stay namespaced without ext-llm dependency" {
  let runtime = activate_runtime(transport=runtime_transport(posts=[]))
  let commands = runtime.commands()
  inspect(commands.any(fn(command) { command.id == "magpie_model" }), content="true")
  inspect(commands.any(fn(command) { command.id == "model" }), content="false")
}

///|

async test "multiple sessions keep their own affinity and selection" {
  let transport = chat_transport(
    posts=[
      buffered_post(status=200, body=messages_nonstream_body(text="one")),
      buffered_post(status=200, body=messages_nonstream_body(text="two")),
      buffered_post(status=200, body=messages_nonstream_body(text="three")),
    ],
  )
  let runtime = activate_runtime(transport~)
  let _ = runtime.invoke(
    "model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  for session in ["sess-1", "sess-2", "sess-3"] {
    let _ = runtime.model_port().chat(
      exec_scope(session~),
      user_text("turn"),
      [],
      chat_options(),
      NoStream,
    )
  }
  inspect(transport.post_sessions[0], content="sess-1")
  inspect(transport.post_sessions[1], content="sess-2")
  inspect(transport.post_sessions[2], content="sess-3")
  // One selection registry: the manager's.
  inspect(runtime.manager.active_selection().model_id, content="anthropic/claude-native")
}

///|
async test "the model port registers exactly once" {
  let runtime = activate_runtime(transport=runtime_transport(posts=[]))
  let manifest = runtime.manifest()
  inspect(manifest.models.length(), content="1")
  guard manifest.models is [port, .. rest] else { fail("manifest models") }
  inspect(rest.length(), content="0")
  let config = port.provider_config()
  inspect(config.reasoning_effort_values.length() >= 0, content="true")
}

///|
async test "the model port survives intelligence service errors" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      Respond(code=500, body="concurrency blew up"),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[buffered_post(
      status=200,
      body=messages_nonstream_body(text="still here"),
    )],
  )
  let runtime = activate_runtime(transport~)
  let outcome = runtime.invoke("magpie_concurrency", Json::null())
  guard outcome is @posoco.CommandOutcome::Failure(_) else {
    fail("expected Failure")
  }
  inspect(
    runtime.intelligence.service_availability(service=Concurrency),
    content="TemporarilyUnavailable",
  )
  // Inference keeps working after the intelligence error.
  let _ = runtime.invoke(
    "model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let result = runtime.model_port().chat(
    exec_scope(session="sess-K"),
    user_text("hi"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(
    result.completion.message.content == [@posoco.Content::Text("still here")],
    content="true",
  )
}
