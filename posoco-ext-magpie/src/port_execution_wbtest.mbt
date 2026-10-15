///|
/// port_execution_wbtest.mbt — ModelPort execution against the fake
/// gateway: deterministic, offline, covering the #110 matrix.

///|
/// The shared execution catalog: one native model per protocol, an
/// endpoint-less (translated-only) model, and a routing group.
fn exec_catalog_body() -> String {
  models_body(
    model_entry(
      id="anthropic/claude-native",
      name="Claude Native",
      owned_by="anthropic",
      fields="\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"low\"},{\"effort\":\"high\"}],\"context_window\":200000,\"native_endpoints\":[\"/v1/messages\"],\"modalities\":{\"input\":[\"text\",\"image\"]}",
    ) +
    "," +
    model_entry(
      id="codex/gpt-responses",
      name="GPT Responses",
      owned_by="codex",
      fields="\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"low\"},{\"effort\":\"high\"}],\"context_window\":922000,\"native_endpoints\":[\"/v1/responses\"],\"modalities\":{\"input\":[\"text\",\"image\"]}",
    ) +
    "," +
    model_entry(
      id="openai/gpt-chat",
      name="GPT Chat",
      owned_by="openai",
      fields="\"reasoning\":false,\"supported_reasoning_levels\":[],\"context_window\":128000,\"native_endpoints\":[\"/v1/chat/completions\"],\"modalities\":{\"input\":[\"text\"]}",
    ) +
    "," +
    model_entry(
      id="relay/translated-only",
      name="Translated Only",
      owned_by="relay",
      fields="\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"high\"}],\"context_window\":8192",
    ) +
    "," +
    model_entry(
      id="group/auto",
      name="Auto Group",
      owned_by="codex",
      fields="\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"high\"}],\"context_window\":1048576,\"modalities\":{\"input\":[\"text\"]}",
    ),
  )
}

///|
fn chat_transport(posts~ : Array[FakePostStep]) -> FakeTransport {
  FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts~,
  )
}

///|
fn exec_scope(session~ : String) -> @posoco.InvocationScope {
  @posoco.InvocationScope::{
    session_id: @posoco.SessionId::unchecked(session),
    run_id: @posoco.RunId::unchecked("run-1"),
    effect_id: None,
    pressure: None,
  }
}

///|
fn chat_options() -> @posoco.ChatOptions {
  { temperature: None, max_output_tokens: None, }
}

///|
fn capturing_sink(
  log : Ref[Array[MagpieExecutionReport]],
) -> (MagpieExecutionReport) -> Unit {
  fn(report) { log.val.push(report) }
}

///|
fn user_text(text : String) -> Array[@posoco.Message] {
  [@posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])]
}

///|
/// Selects a model through the manager-neutral surface and returns the
/// port wired to the same manager and transport.
fn select_and_port(
  manager : MagpieManager,
  model_id : String,
  policy~ : MagpieTranslationPolicy = NativeOnly,
  preference~ : MagpiePreference = Any,
  require_signed_thinking_replay~ : Bool = false,
  require_native_prompt_caching~ : Bool = false,
  require_reasoning_output~ : Bool = false,
  report_log~ : Ref[Array[MagpieExecutionReport]] = Ref([]),
) -> MagpieModelPort raise {
  let control = manager as &@modelmgmt.ModelManagerControl
  control.select_model(model_id)
  MagpieModelPort::MagpieModelPort(
    manager~,
    transport=transport_of(manager),
    policy~,
    preference~,
    require_signed_thinking_replay~,
    require_native_prompt_caching~,
    require_reasoning_output~,
    report_sink=capturing_sink(report_log),
  )
}

///|
async test "native messages execution streams with signed-thinking fidelity" {
  let transport = chat_transport(posts=[
    streaming_post(status=200, lines=messages_thinking_stream()),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let reports : Ref[Array[MagpieExecutionReport]] = Ref([])
  let port = select_and_port(
    manager,
    "anthropic/claude-native",
    require_signed_thinking_replay=true,
    report_log=reports,
  )
  let chunks : Array[@posoco.StreamChunk] = []
  let result = port.chat(
    exec_scope(session="sess-A"),
    user_text("think then answer"),
    [],
    chat_options(),
    Stream(fn(chunk) { chunks.push(chunk) }),
  )
  let mut text_deltas = 0
  for chunk in chunks {
    match chunk {
      @posoco.StreamChunk::TextDelta(_) => text_deltas += 1
      _ => ()
    }
  }
  inspect(text_deltas, content="1")
  inspect(
    result.completion.message.content == [@posoco.Content::Text("the answer")],
    content="true",
  )
  // Thinking block with its signature is preserved for replay.
  guard result.completion.message.reasoning is Some(reasoning) else {
    fail("thinking must survive")
  }
  inspect(reasoning.content, content="figuring it out")
  guard reasoning.raw is Some(raw) else { fail("replay envelope lost") }
  let raw_text = raw.stringify()
  inspect(raw_text.contains("sig-abc=="), content="true")
  inspect(raw_text.contains("thinking"), content="true")
  let usage = result.completion.usage.unwrap()
  inspect(usage.input_tokens == Some(9), content="true")
  inspect(usage.output_tokens == Some(21), content="true")
  let report = reports.val[0]
  inspect(report.protocol, content="Messages")
  inspect(report.kind, content="Native")
  inspect(report.requested_model, content="anthropic/claude-native")
  inspect(report.served_model == Some("claude-served"), content="true")
  inspect(report.response_id == Some("msg_think"), content="true")
  inspect(report.session_identified, content="true")
  inspect(report.lossy_opt_in, content="false")
}

///|
async test "session affinity is stable per session and isolated across sessions" {
  let transport = chat_transport(posts=[
    buffered_post(status=200, body=messages_nonstream_body(text="one")),
    buffered_post(status=200, body=messages_nonstream_body(text="two")),
    buffered_post(status=200, body=messages_nonstream_body(text="three")),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let port = select_and_port(manager, "anthropic/claude-native")
  let _ = port.chat(
    exec_scope(session="sess-A"),
    user_text("first"),
    [],
    chat_options(),
    NoStream,
  )
  let _ = port.chat(
    exec_scope(session="sess-A"),
    user_text("second"),
    [],
    chat_options(),
    NoStream,
  )
  let _ = port.chat(
    exec_scope(session="sess-B"),
    user_text("other session"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(transport.post_sessions[0], content="sess-A")
  inspect(transport.post_sessions[1], content="sess-A")
  inspect(transport.post_sessions[2], content="sess-B")
  // The opaque model ID travels verbatim at the declared endpoint.
  inspect(
    transport.post_calls[0].contains("\"model\":\"anthropic/claude-native\""),
    content="true",
  )
  inspect(transport.post_calls[0].contains("/v1/messages"), content="true")
  // The local application credential authenticates the call.
  inspect(transport.post_auths[0], content="Bearer magpie-posoco")
}

///|
async test "native responses execution parses completions and replays reasoning items" {
  let reasoning_item = Json::object({
    "type": Json::string("reasoning"),
    "summary": Json::array([]),
    "encrypted_content": Json::string("enc-1"),
  })
  let transport = chat_transport(posts=[
    buffered_post(
      status=200,
      body=responses_nonstream_body(text="hi there", reasoning_item~),
    ),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let reports : Ref[Array[MagpieExecutionReport]] = Ref([])
  let port = select_and_port(manager, "codex/gpt-responses", report_log=reports)
  let result = port.chat(
    exec_scope(session="sess-R"),
    user_text("hello"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(
    result.completion.message.content == [@posoco.Content::Text("hi there")],
    content="true",
  )
  guard result.completion.message.reasoning is Some(reasoning) else {
    fail("reasoning items lost")
  }
  let raw_text = reasoning.raw.unwrap().stringify()
  inspect(raw_text.contains("enc-1"), content="true")
  let report = reports.val[0]
  inspect(report.protocol, content="Responses")
  inspect(report.kind, content="Native")
  inspect(report.usage.unwrap().input_tokens == Some(11), content="true")
  inspect(report.response_id == Some("resp_1"), content="true")
  inspect(report.served_model == Some("gpt-responses-served"), content="true")
}

///|
async test "native chat completions execution decodes buffered completions" {
  let transport = chat_transport(posts=[
    buffered_post(status=200, body=chat_nonstream_body(text="hello from chat")),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let reports : Ref[Array[MagpieExecutionReport]] = Ref([])
  let port = select_and_port(manager, "openai/gpt-chat", report_log=reports)
  let result = port.chat(
    exec_scope(session="sess-C"),
    user_text("hello"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(
    result.completion.message.content ==
    [@posoco.Content::Text("hello from chat")],
    content="true",
  )
  inspect(result.completion.message.finish_reason, content="Stop")
  let report = reports.val[0]
  inspect(report.protocol, content="ChatCompletions")
  inspect(report.kind, content="Native")
  inspect(report.usage.unwrap().total_tokens == Some(7), content="true")
  inspect(result.completion.message.reasoning is None, content="true")
}

///|
async test "responses streaming emits text deltas and preserves reasoning replay" {
  let transport = chat_transport(posts=[
    streaming_post(status=200, lines=responses_text_stream()),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let port = select_and_port(manager, "codex/gpt-responses")
  let chunks : Array[@posoco.StreamChunk] = []
  let result = port.chat(
    exec_scope(session="sess-RS"),
    user_text("hello"),
    [],
    chat_options(),
    Stream(fn(chunk) { chunks.push(chunk) }),
  )
  inspect(
    result.completion.message.content == [@posoco.Content::Text("hello")],
    content="true",
  )
  let mut usage_chunks = 0
  for chunk in chunks {
    match chunk {
      @posoco.StreamChunk::Usage(..) => usage_chunks += 1
      _ => ()
    }
  }
  inspect(usage_chunks, content="1")
}

///|
async test "routing-group execution rides the gateway and keeps the group id" {
  let transport = chat_transport(posts=[
    buffered_post(status=200, body=messages_nonstream_body(text="group answer")),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let reports : Ref[Array[MagpieExecutionReport]] = Ref([])
  let port = select_and_port(
    manager,
    "group/auto",
    policy=AllowTranslated,
    report_log=reports,
  )
  let _ = port.chat(
    exec_scope(session="sess-G"),
    user_text("route me"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(
    transport.post_calls[0].contains("\"model\":\"group/auto\""),
    content="true",
  )
  let report = reports.val[0]
  inspect(report.requested_model, content="group/auto")
  inspect(report.kind, content="GatewayTranslated")
  // AllowTranslated is the opt-in: translated plans are marked lossy.
  inspect(report.lossy_opt_in, content="true")
}

///|
async test "translated execution requires the explicit opt-in and reports it" {
  let strict_transport = chat_transport(posts=[])
  let strict_manager = manager_with(
    transport=strict_transport,
    config=local_config(),
  )
  refresh_ok(strict_manager)
  let strict_port = select_and_port(
    strict_manager,
    "codex/gpt-responses",
    require_signed_thinking_replay=true,
  )
  try
    strict_port.chat(
      exec_scope(session="sess-X"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  catch {
    @posoco.ModelError::RequestBuild(detail) =>
      inspect(detail.contains("no protocol satisfies"), content="true")
    _ => fail("expected RequestBuild")
  } noraise {
    _ => fail("strict fidelity must reject")
  }
  let lossy_transport = chat_transport(posts=[
    buffered_post(status=200, body=messages_nonstream_body(text="lossy ok")),
  ])
  let lossy_manager = manager_with(
    transport=lossy_transport,
    config=local_config(),
  )
  refresh_ok(lossy_manager)
  let reports : Ref[Array[MagpieExecutionReport]] = Ref([])
  let lossy_port = select_and_port(
    lossy_manager,
    "relay/translated-only",
    policy=AllowTranslated,
    require_signed_thinking_replay=true,
    report_log=reports,
  )
  let result = lossy_port.chat(
    exec_scope(session="sess-X"),
    user_text("hi"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(
    result.completion.message.content == [@posoco.Content::Text("lossy ok")],
    content="true",
  )
  let report = reports.val[0]
  inspect(report.lossy_opt_in, content="true")
  inspect(report.kind, content="GatewayTranslated")
}

///|
async test "pending selections are rejected before any request" {
  let reduced_catalog = models_body(
    model_entry(id="other/only", owned_by="relay"),
  )
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=reduced_catalog),
    ],
    posts=[
      buffered_post(status=200, body=messages_nonstream_body(text="never")),
    ],
  )
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let port = select_and_port(manager, "anthropic/claude-native")
  // The gateway drops the selected model: the selection goes pending.
  refresh_ok(manager)
  try
    port.chat(
      exec_scope(session="sess-P"),
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
    _ => fail("pending selections must be rejected")
  }
  // The rejection happened before any request was sent.
  inspect(transport.post_calls.length(), content="0")
}

///|
async test "tool-call round trips preserve identities and arguments" {
  let transport = chat_transport(posts=[
    streaming_post(status=200, lines=messages_tool_stream()),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let port = select_and_port(manager, "anthropic/claude-native")
  let sink = fn(_chunk : @posoco.StreamChunk) { () }
  let result = port.chat(
    exec_scope(session="sess-T"),
    user_text("read the file"),
    [],
    chat_options(),
    Stream(sink),
  )
  let calls = result.completion.message.tool_calls
  inspect(calls.length(), content="1")
  inspect(calls[0].call_id.to_string(), content="toolu_1")
  inspect(calls[0].name.to_string(), content="read")
  inspect(calls[0].arguments.stringify(), content="{\"path\":\"x\"}")
  inspect(result.completion.message.finish_reason, content="ToolCalls")
}

///|
async test "parallel tool calls assemble separately in one stream" {
  let transport = chat_transport(posts=[
    streaming_post(status=200, lines=chat_parallel_tool_stream()),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let port = select_and_port(manager, "openai/gpt-chat")
  let sink = fn(_chunk : @posoco.StreamChunk) { () }
  let result = port.chat(
    exec_scope(session="sess-P"),
    user_text("read two files"),
    [],
    chat_options(),
    Stream(sink),
  )
  let calls = result.completion.message.tool_calls
  inspect(calls.length(), content="2")
  inspect(calls[0].call_id.to_string(), content="call_a")
  inspect(calls[0].arguments.stringify(), content="{\"path\":\"a\"}")
  inspect(calls[1].call_id.to_string(), content="call_b")
  inspect(calls[1].name.to_string(), content="stat")
  inspect(calls[1].arguments.stringify(), content="{\"path\":\"b\"}")
  inspect(result.completion.message.finish_reason, content="ToolCalls")
}

///|
async test "incomplete streams are detected, not completed silently" {
  let transport = chat_transport(posts=[
    streaming_post(status=200, lines=messages_truncated_stream()),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let port = select_and_port(manager, "anthropic/claude-native")
  try
    port.chat(
      exec_scope(session="sess-I"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  catch {
    @posoco.ModelError::ResponseParse(_) => ()
    _ => fail("expected ResponseParse")
  } noraise {
    _ => fail("truncated stream must raise")
  }
}

///|
async test "gateway authentication failures map to transport errors" {
  let transport = chat_transport(posts=[
    buffered_post(status=401, body="{\"error\":\"bad key\"}"),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let port = select_and_port(manager, "anthropic/claude-native")
  try
    port.chat(
      exec_scope(session="sess-AU"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  catch {
    @posoco.ModelError::Transport(detail) =>
      inspect(detail.contains("401"), content="true")
    _ => fail("expected Transport")
  } noraise {
    _ => fail("401 must raise")
  }
}

///|
async test "rate limits carry the structured verdict; 5xx stays a transport error" {
  let transport = chat_transport(posts=[
    buffered_post(status=429, body="rate limit exceeded, retry at 12:00Z"),
    buffered_post(status=503, body="upstream unavailable"),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let port = select_and_port(manager, "anthropic/claude-native")
  try
    port.chat(
      exec_scope(session="sess-RL"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  catch {
    @posoco.ModelError::RateLimited(info) =>
      inspect(info.message.contains("rate limit"), content="true")
    _ => fail("expected RateLimited")
  } noraise {
    _ => fail("429 must raise the structured verdict")
  }
  try
    port.chat(
      exec_scope(session="sess-RL"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  catch {
    @posoco.ModelError::Transport(detail) => {
      inspect(detail.contains("503"), content="true")
      // Bounded diagnostics: the body is counted, never quoted.
      inspect(detail.contains("unavailable"), content="false")
    }
    _ => fail("expected Transport")
  } noraise {
    _ => fail("503 must raise")
  }
}

///|
async test "usage accounting preserves native cache information" {
  let usage_body = Json::object({
    "type": Json::string("message"),
    "id": Json::string("msg_usage"),
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
  }).stringify()
  let transport = chat_transport(posts=[
    buffered_post(status=200, body=usage_body),
  ])
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let reports : Ref[Array[MagpieExecutionReport]] = Ref([])
  let port = select_and_port(
    manager,
    "anthropic/claude-native",
    report_log=reports,
  )
  let result = port.chat(
    exec_scope(session="sess-U"),
    user_text("hi"),
    [],
    chat_options(),
    NoStream,
  )
  // Canonical input is the full prompt total (fresh + cache-read + write).
  let usage = result.completion.usage.unwrap()
  inspect(usage.input_tokens == Some(190), content="true")
  inspect(usage.output_tokens == Some(5), content="true")
  let report = reports.val[0]
  // Native cache numbers stay separate, not folded into one counter.
  inspect(report.cache_read_tokens == Some(80), content="true")
  inspect(report.cache_write_tokens == Some(10), content="true")
  inspect(report.finish_reason == @posoco.FinishReason::Stop, content="true")
}

///|
async test "a catalog refresh invalidating the plan is honored on the next call" {
  let responses_only = models_body(
    model_entry(
      id="codex/gpt-responses",
      owned_by="codex",
      fields="\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"high\"}],\"context_window\":922000,\"native_endpoints\":[\"/v1/responses\"],\"modalities\":{\"input\":[\"text\",\"image\"]}",
    ),
  )
  let with_messages = models_body(
    model_entry(
      id="codex/gpt-responses",
      owned_by="codex",
      fields="\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"high\"}],\"context_window\":922000,\"native_endpoints\":[\"/v1/responses\",\"/v1/messages\"],\"modalities\":{\"input\":[\"text\",\"image\"]}",
    ),
  )
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=responses_only),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=with_messages),
    ],
    posts=[
      buffered_post(status=200, body=messages_nonstream_body(text="native now")),
    ],
  )
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let reports : Ref[Array[MagpieExecutionReport]] = Ref([])
  let port = select_and_port(
    manager,
    "codex/gpt-responses",
    require_signed_thinking_replay=true,
    report_log=reports,
  )
  // Signed thinking needs native Messages; the catalog declares none.
  try
    port.chat(
      exec_scope(session="sess-V"),
      user_text("hi"),
      [],
      chat_options(),
      NoStream,
    )
  catch {
    @posoco.ModelError::RequestBuild(_) => ()
    _ => fail("expected RequestBuild")
  } noraise {
    _ => fail("must reject without native Messages")
  }
  // The gateway now declares native Messages: the same port and selection
  // replan and execute natively at the declared endpoint.
  refresh_ok(manager)
  let _ = port.chat(
    exec_scope(session="sess-V"),
    user_text("hi"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(transport.post_calls[0].contains("/v1/messages"), content="true")
  inspect(reports.val[0].kind, content="Native")
  inspect(reports.val[0].protocol, content="Messages")
}

///|
async test "identical executions produce identical request shapes" {
  let transport_a = chat_transport(posts=[
    buffered_post(status=200, body=messages_nonstream_body(text="x")),
  ])
  let transport_b = chat_transport(posts=[
    buffered_post(status=200, body=messages_nonstream_body(text="x")),
  ])
  let manager_a = manager_with(transport=transport_a, config=local_config())
  refresh_ok(manager_a)
  let port_a = select_and_port(manager_a, "anthropic/claude-native")
  let manager_b = manager_with(transport=transport_b, config=local_config())
  refresh_ok(manager_b)
  let port_b = select_and_port(manager_b, "anthropic/claude-native")
  let _ = port_a.chat(
    exec_scope(session="sess-S"),
    user_text("stable"),
    [],
    chat_options(),
    NoStream,
  )
  let _ = port_b.chat(
    exec_scope(session="sess-S"),
    user_text("stable"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(
    transport_a.post_calls[0] == transport_b.post_calls[0],
    content="true",
  )
}

///|
async test "streaming execution is cancellable mid-stream" {
  let transport = chat_transport(posts=[
    streaming_post(status=200, lines=messages_thinking_stream()),
  ])
  transport.delay_ms = 30
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let port = select_and_port(manager, "anthropic/claude-native")
  let sink = fn(_chunk : @posoco.StreamChunk) { () }
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      let _ = port.chat(
        exec_scope(session="sess-K"),
        user_text("hi"),
        [],
        chat_options(),
        Stream(sink),
      )
    })
    // Land the cancellation in the middle of the scripted stream.
    @async.sleep(50)
    task.cancel()
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => fail("cancellation surfaced the wrong error: \{error}")
    }
  })
}

///|
/// Unknown image modality must not trigger implicit placeholder conversion.
test "unknown image modality preserves original image blocks" {
  let entry = decode_catalog(
      models_body(
        model_entry(
          id="x/unknown-image",
          fields="\"native_endpoints\":[\"/v1/messages\"]",
        ),
      ),
    ).entries[0]
  inspect(entry.meta.modalities_input is None, content="true")
  inspect(model_supports_images(entry), content="true")
  let input : Array[@posoco.Content] = [
    @posoco.Content::Image(media_type="image/png", data="aGVsbG8="),
  ]
  let shaped = shape_for_images(
    [@posoco.Message::UserMessage(content=input)],
    model_supports_images(entry),
  )
  inspect(
    shaped == [@posoco.Message::UserMessage(content=input)],
    content="true",
  )
}

///|
/// A text-only model must replace image blocks with the explicit
/// placeholder — the downgrade is visible in the payload, never silent.
test "text-only model downgrades images to an explicit placeholder" {
  let entry = decode_catalog(
      models_body(
        model_entry(
          id="openai/gpt-chat",
          fields="\"reasoning\":false,\"supported_reasoning_levels\":[],\"context_window\":128000,\"native_endpoints\":[\"/v1/chat/completions\"],\"modalities\":{\"input\":[\"text\"]}",
        ),
      ),
    ).entries[0]
  inspect(model_supports_images(entry), content="false")
  let input : Array[@posoco.Content] = [
    @posoco.Content::Text("look at this"),
    @posoco.Content::Image(media_type="image/png", data="aGVsbG8="),
  ]
  let shaped = shape_for_images(
    [@posoco.Message::UserMessage(content=input)],
    model_supports_images(entry),
  )
  guard
    shaped[0] is @posoco.Message::UserMessage(content=blocks) else {
    fail("user message must stay a user message")
  }
  inspect(blocks.length(), content="2")
  guard blocks[1] is @posoco.Content::Text(placeholder) else {
    fail("the image block must be downgraded to text")
  }
  inspect(placeholder.contains("image/png"), content="true")
  inspect(placeholder.contains("does not accept image input"), content="true")
}
