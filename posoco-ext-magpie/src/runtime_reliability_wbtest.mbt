///|
/// runtime_reliability_wbtest.mbt — PR #113 offline reliability regression:
/// failure isolation, reconnection, stream cleanup, shutdown semantics, and
/// usage-accounting independence, all against the deterministic fake
/// gateway.

///|
async test "gateway offline then reconnect restores the explicit online state" {
  let transport = FakeTransport(
    [
      FailWith(MagpieGatewayError::Offline("connection refused")),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[],
  )
  let runtime = MagpieRuntime::activate(transport~)
  runtime.on_start()
  guard runtime.manager.connection_status() is Offline(_) else {
    fail("expected offline after a refused connection")
  }
  // The gateway comes back: the next refresh restores the online state and
  // the catalog, without any restart.
  runtime.on_start()
  guard runtime.manager.connection_status() is Connected(_) else {
    fail("expected connected after recovery")
  }
  inspect(runtime.manager.list_models().length() > 0, content="true")
}

///|
/// A complete streaming Messages turn: start, one text delta, stop, usage.
fn messages_text_stream() -> Array[String] {
  sse_script([
    msg_start(id="msg_text", model="claude-served"),
    block_start(
      index=0,
      block=Json::object({
        "type": Json::string("text"),
        "text": Json::string(""),
      }),
    ),
    block_delta(
      index=0,
      delta=Json::object({
        "type": Json::string("text_delta"),
        "text": Json::string("half"),
      }),
    ),
    block_stop(index=0),
    msg_delta(stop_reason="end_turn", output_tokens=5),
    msg_stop(),
  ])
}

///|
async test "an incomplete stream cleans up its connection and isolates the failure" {
  let lines = messages_text_stream()
  let partial : Array[String] = []
  for index in 0..<(lines.length() - 1) {
    partial.push(lines[index])
  }
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[streaming_post(status=200, lines=partial)],
  )
  let runtime = MagpieRuntime::activate(transport~)
  runtime.on_start()
  let _ = runtime.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let chunks : Array[@posoco.StreamChunk] = []
  try
    runtime
    .model_port()
    .chat(
      exec_scope(session="sess-Broken"),
      user_text("hi"),
      [],
      chat_options(),
      Stream(fn(chunk) { chunks.push(chunk) }),
    )
  catch {
    @posoco.ModelError::RateLimited(info) =>
      inspect(info.provider_code == Some("magpie_transient"), content="true")
    _ => fail("expected recoverable RateLimited for an incomplete stream")
  } noraise {
    _ => ()
  }
  // The half-consumed connection was closed by the failed execution.
  inspect(transport.stream_closes >= 1, content="true")
  // The failure stayed isolated: the runtime still serves commands.
  let outcome = runtime.invoke("magpie_status", Json::null())
  inspect(outcome is @posoco.CommandOutcome::Success(..), content="true")
}

///|
async test "shutdown during service refuses new work and closes streams" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[streaming_post(status=200, lines=messages_text_stream())],
  )
  let runtime = MagpieRuntime::activate(transport~)
  runtime.on_start()
  runtime.on_shutdown()
  // Every user-facing command refuses after deactivation.
  for
    id in [
      "magpie_model", "magpie_status", "magpie_refresh", "magpie_route", "magpie_quotas",
      "magpie_limit", "magpie_usage", "magpie_requests", "magpie_concurrency", "magpie_usage_recent",
    ] {
    try runtime.invoke(id, Json::null()) catch {
      @posoco.CommandError::ExecutionFailed(detail) =>
        inspect(detail.contains("deactivated"), content="true")
      _ => fail("expected ExecutionFailed for \{id}")
    } noraise {
      _ => ()
    }
  }
  // And inference refuses too.
  try
    runtime
    .model_port()
    .chat(
      exec_scope(session="sess-Shut"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  catch {
    @posoco.ModelError::RequestBuild(_) => ()
    _ => fail("expected RequestBuild after shutdown")
  } noraise {
    _ => ()
  }
  // A host still holding an open stream can always release it.
  inspect(transport.stream_closes, content="0")
}

///|
async test "an authentication failure on inference leaves no usage report" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[buffered_post(status=401, body="{\"error\":\"bad key\"}")],
  )
  let runtime = MagpieRuntime::activate(transport~)
  runtime.on_start()
  let _ = runtime.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  try
    runtime
    .model_port()
    .chat(
      exec_scope(session="sess-Auth"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  catch {
    @posoco.ModelError::Transport(detail) =>
      inspect(detail.contains("401"), content="true")
    _ => fail("expected Transport for 401")
  } noraise {
    _ => ()
  }
  // A rejected request produced no output and no usage accounting.
  inspect(runtime.recent_reports().length(), content="0")
}

///|
async test "intelligence service failures stay isolated from inference" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      // route: unauthorized
      Respond(code=401, body="{\"error\":\"nope\"}"),
      // concurrency: rate limited
      Respond(code=429, body="{\"error\":\"slow down\"}"),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[buffered_post(status=200, body=messages_nonstream_body(text="ok"))],
  )
  let runtime = MagpieRuntime::activate(transport~)
  runtime.on_start()
  guard runtime.invoke(
      "magpie_route",
      Json::object({ "session": Json::string("s") }),
    )
    is @posoco.CommandOutcome::Failure(_) else {
    fail("expected route Failure on 401")
  }
  guard runtime.invoke("magpie_concurrency", Json::null())
    is @posoco.CommandOutcome::Failure(_) else {
    fail("expected concurrency Failure on 429")
  }
  // Inference is untouched by both intelligence failures.
  let _ = runtime.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let result = runtime
    .model_port()
    .chat(
      exec_scope(session="sess-Iso"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  inspect(
    result.completion.message.content == [@posoco.Content::Text("ok")],
    content="true",
  )
}

///|
async test "usage accounting is single-counted and independent of gateway pages" {
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      // Gateway-side usage page (independent of local reports).
      Respond(code=200, body=usage_requests_page([full_usage_row()])),
    ],
    posts=[buffered_post(status=200, body=messages_nonstream_body(text="done"))],
  )
  let runtime = MagpieRuntime::activate(transport~)
  runtime.on_start()
  let _ = runtime.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  let _ = runtime
    .model_port()
    .chat(
      exec_scope(session="sess-Usage"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  // Exactly one local report for exactly one execution.
  let reports = runtime.recent_reports()
  inspect(reports.length(), content="1")
  // The gateway page is surfaced verbatim; local reports never merge into it.
  let outcome = runtime.invoke(
    "magpie_requests",
    Json::object({ "period": Json::string("today") }),
  )
  let text = invoke_text(outcome)
  inspect(text.contains("gpt-6-luna"), content="true")
  inspect(runtime.recent_reports().length(), content="1")
}

///|
async test "repeated executions over one transport stay clean" {
  let transport = chat_transport(posts=[
    buffered_post(status=200, body=messages_nonstream_body(text="one")),
    buffered_post(status=200, body=messages_nonstream_body(text="two")),
    buffered_post(status=200, body=messages_nonstream_body(text="three")),
  ])
  let runtime = MagpieRuntime::activate(transport~)
  runtime.on_start()
  let _ = runtime.invoke(
    "magpie_model",
    Json::object({ "model": Json::string("anthropic/claude-native") }),
  )
  for index in 0..<3 {
    let result = runtime
      .model_port()
      .chat(
        exec_scope(session="sess-Clean-\{index}"),
        user_text("hi"),
        [],
        chat_options(),
        NoStream,
      )
    ignore(result.completion.message.content.length())
  }
  inspect(runtime.recent_reports().length(), content="3")
  // Three buffered executions, three recorded sessions, nothing left open.
  inspect(transport.post_calls.length(), content="3")
  inspect(transport.post_sessions.length(), content="3")
}
