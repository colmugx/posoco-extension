///|
/// Public-entry contract tests for the DeepSeek model port and provider
/// factory. Every test drives the production `ModelPort::chat` /
/// `ProviderFactory::build` / `RefreshableProviderFactory::refresh` entries
/// against an ephemeral in-process HTTP loopback; no transport seam is added.
/// Native only (loopback sockets), matching the moon.pkg targets map.

///|
/// One scripted HTTP response.
priv struct LoopbackReply {
  status : Int32
  body : String
}

///|
fn LoopbackReply::ok(body : String) -> LoopbackReply {
  { status: 200, body, }
}

///|
/// Loopback server recording request paths, bodies, and Authorization
/// headers; replies come from a script whose last entry repeats.
struct DeepSeekLoopback {
  server : @http.Server
  replies : Array[LoopbackReply]
  paths : Array[String]
  bodies : Array[String]
  auths : Array[String?]
  mut next_reply : Int32
  mut stopping : Bool
}

///|
// Test-helper failure is deliberately ordinary Result data.
#warnings("-result_error_return")
async fn[T] attempt_async(f : async () -> T) -> Result[T, Error] {
  Ok(f()) catch {
    e => Err(e)
  }
}

///|
async fn DeepSeekLoopback::bind(
  replies : Array[LoopbackReply],
) -> DeepSeekLoopback {
  // Ephemeral port: bind on 0, read the port, close, rebind.
  let probe = @socket.TcpServer(@socket.Addr::resolve("127.0.0.1", port=0)) catch {
    _ => fail("loopback probe bind failed")
  }
  let port = probe.addr.port()
  probe.close()
  let server = @http.Server(@socket.Addr::resolve("127.0.0.1", port~)) catch {
    _ => fail("loopback server bind failed")
  }
  {
    server,
    replies,
    paths: [],
    bodies: [],
    auths: [],
    next_reply: 0,
    stopping: false,
  }
}

///|
async fn DeepSeekLoopback::serve(self : DeepSeekLoopback) -> Unit {
  while !self.stopping {
    let accepted = attempt_async(() => {
      @async.with_timeout(200, () => self.server.accept())
    })
    let (conn, _) = match accepted {
      Ok(accepted) => accepted
      Err(error) => {
        if self.stopping {
          return
        }
        match error {
          @async.TimeoutError => continue
          _ => raise error
        }
      }
    }
    defer conn.close()
    let request = conn.read_request()
    self.paths.push(request.path)
    self.auths.push(request.headers.get("authorization"))
    let buf = StringBuilder()
    while conn.read_some() is Some(data) {
      buf.write_string(@utf8.decode(data))
    }
    self.bodies.push(buf.to_string())
    guard self.replies.length() > 0 else {
      fail("loopback has no scripted reply")
    }
    let index = if self.next_reply < self.replies.length() {
      self.next_reply
    } else {
      self.replies.length() - 1
    }
    self.next_reply += 1
    let reply = self.replies[index]
    conn.send_response(reply.status, "OK")
    conn.write_string(reply.body)
    conn.end_response()
    conn.close()
  }
}

///|
fn DeepSeekLoopback::stop(self : DeepSeekLoopback) -> Unit {
  if self.stopping {
    return
  }
  self.stopping = true
  self.server.close()
}

///|
/// Run `f` with the loopback base URL, returning the outcome plus the
/// recorded server transcript. Bounded so a regression fails instead of
/// hanging the suite.
async fn[T] contract_with_loopback(
  replies : Array[LoopbackReply],
  f : async (String, DeepSeekLoopback) -> T,
) -> (T, DeepSeekLoopback) {
  let loopback = DeepSeekLoopback::bind(replies)
  let value = @async.with_task_group() <| group => {
    let _ = group.spawn(() => loopback.serve())
    let outcome = attempt_async(() => {
      @async.with_timeout(20000, () => {
        f("http://127.0.0.1:\{loopback.server.addr.port()}", loopback)
      })
    })
    loopback.stop()
    match outcome {
      Ok(value) => value
      Err(e) => raise e
    }
  }
  (value, loopback)
}

///|
fn contract_scope() -> @posoco.InvocationScope {
  @posoco.InvocationScope::{
    session_id: @posoco.SessionId::unchecked("contract-loopback"),
    run_id: @posoco.RunId::unchecked("run-1"),
    effect_id: None,
    pressure: None,
  }
}

///|
fn contract_messages() -> Array[@posoco.Message] {
  [@posoco.Message::UserMessage(content=[@posoco.Content::Text("q1")])]
}

///|
fn contract_options() -> @posoco.ChatOptions {
  { temperature: None, max_output_tokens: None, }
}

///|
fn contract_source(
  settings : Array[(String, Json)],
) -> @provider.ProviderConfigSource {
  @provider.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object(Map::from_array(settings))),
  )
}

///|
fn contract_source_with(
  base_url : String,
  extra : Array[(String, Json)],
) -> @provider.ProviderConfigSource {
  let pairs : Array[(String, Json)] = [
    ("api_key", Json::string("sk-test")),
    ("base_url", Json::string(base_url)),
  ]
  for pair in extra {
    pairs.push(pair)
  }
  contract_source(pairs)
}

///|
fn contract_body_field(body : String, key : String) -> Json? raise {
  guard @json.parse(body) is Json::Object(fields) else {
    fail("request body must be a JSON object")
  }
  fields.get(key)
}

///|
fn contract_expect_success(
  result : Result[@posoco.ModelCallResult, @posoco.ModelError],
) -> @posoco.ModelCallResult raise {
  match result {
    Ok(value) => value
    Err(error) => fail("expected chat success, got: " + error.to_string())
  }
}

///|
fn contract_expect_transport(
  result : Result[@posoco.ModelCallResult, @posoco.ModelError],
) -> String raise {
  match result {
    Ok(_) => fail("expected the chat call to fail")
    Err(@posoco.ModelError::Transport(message)) => message
    Err(other) => fail("expected Transport, got: " + other.to_string())
  }
}

///|
fn contract_response_body(finish_reason : String, content : String) -> String {
  Json::object({
    "choices": Json::array([
      Json::object({
        "message": Json::object({
          "role": Json::string("assistant"),
          "content": Json::string(content),
        }),
        "finish_reason": Json::string(finish_reason),
      }),
    ]),
    "usage": Json::object({
      "prompt_tokens": Json::number(1.0),
      "completion_tokens": Json::number(1.0),
      "total_tokens": Json::number(2.0),
    }),
  }).stringify()
}

///|
fn contract_sse(events : Array[String]) -> String {
  let buf = StringBuilder()
  for event in events {
    buf.write_string("data: " + event + "\n\n")
  }
  buf.to_string()
}

///|
fn contract_reasoning_chunk(token : String) -> String {
  Json::object({
    "choices": Json::array([
      Json::object({
        "delta": Json::object({ "reasoning_content": Json::string(token) }),
      }),
    ]),
  }).stringify()
}

///|
fn contract_text_chunk(token : String) -> String {
  Json::object({
    "choices": Json::array([
      Json::object({ "delta": Json::object({ "content": Json::string(token) }) }),
    ]),
  }).stringify()
}

///|
fn contract_finish_chunk() -> String {
  Json::object({
    "choices": Json::array([
      Json::object({
        "delta": Json::object({}),
        "finish_reason": Json::string("stop"),
      }),
    ]),
    "usage": Json::object({
      "prompt_tokens": Json::number(5.0),
      "completion_tokens": Json::number(2.0),
      "total_tokens": Json::number(7.0),
    }),
  }).stringify()
}

///|
async test "contract build and refresh report Unconfigured without any credential" {
  let provider = @posoco-ext-deepseek.DeepSeekProvider::DeepSeekProvider()
  let factory : &@provider.ProviderFactory = provider
  let source = contract_source([])
  guard factory.build(source) is @provider.ProviderBuildResult::Unconfigured else {
    fail("build without any credential must be Unconfigured")
  }
  let refreshable : &@provider.RefreshableProviderFactory = provider
  let refreshed = Ok(refreshable.refresh(source)) catch { e => Err(e) }
  guard refreshed is Ok(@provider.ProviderBuildResult::Unconfigured) else {
    fail("refresh without any credential must be Unconfigured")
  }
}

///|
fn contract_expect_effort_error(
  outcome : Result[@provider.ProviderBuildResult, @posoco.CompositionError],
) -> String raise {
  match outcome {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) => detail
    _ => fail("an unsupported effort must fail with a typed schema error")
  }
}

///|
async test "contract build and refresh reject an unsupported effort with the same typed error" {
  let provider = @posoco-ext-deepseek.DeepSeekProvider::DeepSeekProvider()
  let factory : &@provider.ProviderFactory = provider
  let refreshable : &@provider.RefreshableProviderFactory = provider
  let source = contract_source([
    ("api_key", Json::string("sk-test")),
    ("reasoning_effort", Json::string("bogus")),
  ])
  let built = Ok(factory.build(source)) catch { e => Err(e) }
  let refreshed = Ok(refreshable.refresh(source)) catch { e => Err(e) }
  assert_eq(
    contract_expect_effort_error(built),
    "unsupported reasoning_effort: bogus",
  )
  assert_eq(
    contract_expect_effort_error(refreshed),
    "unsupported reasoning_effort: bogus",
  )
}

///|
async test "contract build composes defaults offline without any request" {
  let provider = @posoco-ext-deepseek.DeepSeekProvider::DeepSeekProvider()
  let factory : &@provider.ProviderFactory = provider
  let (catalog, loopback) = contract_with_loopback(
    ([] : Array[LoopbackReply]),
    (base_url : String, _loopback : DeepSeekLoopback) => {
      let source = contract_source_with(base_url, [
        ("context_window", Json::number(32000.0)),
      ])
      match factory.build(source) {
        @provider.ProviderBuildResult::Ready(catalog) => catalog
        @provider.ProviderBuildResult::Unconfigured =>
          fail("a credential alone must compose the provider-owned default")
      }
    },
  )
  // build is offline: it must not dial the configured base_url.
  assert_eq(loopback.paths.length(), 0)
  let slot = catalog.slots()[0]
  assert_eq(slot.model_id, "deepseek-flash")
  assert_eq(slot.default_effort, Some("high"))
  assert_eq(slot.context_window, Some(32000))
  assert_eq(slot.context_window_source, "configured")
  assert_eq(
    slot.port.provider_config(),
    @posoco.ProviderConfig::ProviderConfig(
      reasoning_effort_values=[],
      context_window=Some(32000),
      compact_threshold=Some(0.80),
    ),
  )
}

///|
async test "contract refresh performs exactly one authenticated models request" {
  let provider = @posoco-ext-deepseek.DeepSeekProvider::DeepSeekProvider()
  let refreshable : &@provider.RefreshableProviderFactory = provider
  let models_body = Json::object({
    "object": Json::string("list"),
    "data": Json::array([
      Json::object({
        "id": Json::string("deepseek-chat"),
        "object": Json::string("model"),
        "owned_by": Json::string("deepseek"),
      }),
      Json::object({
        "id": Json::string("deepseek-reasoner"),
        "object": Json::string("model"),
        "owned_by": Json::string("deepseek"),
      }),
    ]),
  }).stringify()
  let (refreshed, loopback) = contract_with_loopback(
    [LoopbackReply::ok(models_body)],
    (base_url, _loopback) => {
      let source = contract_source_with(base_url, [])
      Ok(refreshable.refresh(source)) catch {
        e => Err(e)
      }
    },
  )
  assert_eq(loopback.paths, ["/models"])
  assert_eq(loopback.auths, [Some("Bearer sk-test")])
  guard refreshed is Ok(@provider.ProviderBuildResult::Ready(catalog)) else {
    fail("refresh against a live /models response must be Ready")
  }
  let model_ids = catalog.slots().map(fn(slot) { slot.model_id })
  assert_eq(model_ids, ["deepseek-chat", "deepseek-reasoner"])
}

///|
async test "contract refresh fails composition on a models HTTP error without fallback" {
  let provider = @posoco-ext-deepseek.DeepSeekProvider::DeepSeekProvider()
  let refreshable : &@provider.RefreshableProviderFactory = provider
  let (refreshed, loopback) = contract_with_loopback(
    [{ status: 500, body: "secret-provider-body", }],
    (base_url, _loopback) => {
      let source = contract_source_with(base_url, [])
      Ok(refreshable.refresh(source)) catch {
        e => Err(e)
      }
    },
  )
  assert_eq(loopback.paths, ["/models"])
  guard refreshed
    is Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) else {
    fail("refresh must fail composition when /models fails")
  }
  assert_true(detail.contains("model catalog refresh failed"))
  assert_true(detail.contains("HTTP status: 500"))
  assert_false(detail.contains("secret-provider-body"))
}

///|
async test "contract nonstream chat returns the completion and echoes processed_messages" {
  let (result, loopback) = contract_with_loopback(
    [LoopbackReply::ok(contract_response_body("stop", "hello deepseek"))],
    (base_url, _loopback) => {
      let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
        "sk-test",
        base_url~,
      )
      let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
        config,
      )
      let port : &@posoco.ModelPort = port_impl
      Ok(
        port.chat(
          contract_scope(),
          contract_messages(),
          [],
          contract_options(),
          @posoco.StreamMode::NoStream,
        ),
      ) catch {
        e => Err(e)
      }
    },
  )
  assert_eq(loopback.paths, ["/chat/completions"])
  assert_eq(loopback.bodies.length(), 1)
  let body = loopback.bodies[0]
  assert_eq(
    contract_body_field(body, "model"),
    Some(Json::string("deepseek-flash")),
  )
  assert_eq(
    contract_body_field(body, "thinking"),
    Some(Json::object({ "type": Json::string("enabled") })),
  )
  assert_eq(
    contract_body_field(body, "reasoning_effort"),
    Some(Json::string("high")),
  )
  assert_eq(contract_body_field(body, "stream"), None)
  let value = contract_expect_success(result)
  assert_true(
    value.completion.message.content[0]
    is @posoco.Content::Text("hello deepseek"),
  )
  assert_eq(value.completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_eq(value.processed_messages.length(), 1)
  guard value.processed_messages[0] is @posoco.Message::UserMessage(content~) else {
    fail("processed_messages must echo the request messages unchanged")
  }
  assert_eq(content.length(), 1)
  assert_true(content[0] is @posoco.Content::Text("q1"))
}

///|
async test "contract nonstream reasoning-only cutoff retries once at low effort" {
  let logger = @devkit.MemoryLogger::MemoryLogger()
  let ctx = @devkit.ExtContext::ExtContext(logger~)
  let (result, loopback) = contract_with_loopback(
    [
      LoopbackReply::ok(contract_response_body("length", "")),
      LoopbackReply::ok(contract_response_body("stop", "recovered")),
    ],
    (base_url, _loopback) => {
      let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
        "sk-test",
        base_url~,
      )
      let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
        config,
        ctx~,
      )
      let port : &@posoco.ModelPort = port_impl
      Ok(
        port.chat(
          contract_scope(),
          contract_messages(),
          [],
          contract_options(),
          @posoco.StreamMode::NoStream,
        ),
      ) catch {
        e => Err(e)
      }
    },
  )
  assert_eq(loopback.bodies.length(), 2)
  let first = contract_body_field(loopback.bodies[0], "reasoning_effort")
  let second = contract_body_field(loopback.bodies[1], "reasoning_effort")
  assert_eq(first, Some(Json::string("high")))
  assert_eq(second, Some(Json::string("low")))
  assert_eq(
    contract_body_field(loopback.bodies[1], "thinking"),
    Some(Json::object({ "type": Json::string("enabled") })),
  )
  let value = contract_expect_success(result)
  assert_true(
    value.completion.message.content[0] is @posoco.Content::Text("recovered"),
  )
  let recovery_warns = logger.events.filter(fn(event) {
    event.code == "deepseek.reasoning_exhaustion_recovery"
  })
  assert_eq(recovery_warns.length(), 1)
}

///|
async test "contract nonstream cutoff with answer text does not retry" {
  let (result, loopback) = contract_with_loopback(
    [LoopbackReply::ok(contract_response_body("length", "partial answer"))],
    (base_url, _loopback) => {
      let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
        "sk-test",
        base_url~,
      )
      let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
        config,
      )
      let port : &@posoco.ModelPort = port_impl
      Ok(
        port.chat(
          contract_scope(),
          contract_messages(),
          [],
          contract_options(),
          @posoco.StreamMode::NoStream,
        ),
      ) catch {
        e => Err(e)
      }
    },
  )
  assert_eq(loopback.bodies.length(), 1)
  let value = contract_expect_success(result)
  assert_true(
    value.completion.message.content[0]
    is @posoco.Content::Text("partial answer"),
  )
}

///|
async test "contract nonstream recovery disabled keeps the single cutoff response" {
  let (result, loopback) = contract_with_loopback(
    [LoopbackReply::ok(contract_response_body("length", ""))],
    (base_url, _loopback) => {
      let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
        "sk-test",
        base_url~,
        recover_on_reasoning_exhaustion=false,
      )
      let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
        config,
      )
      let port : &@posoco.ModelPort = port_impl
      Ok(
        port.chat(
          contract_scope(),
          contract_messages(),
          [],
          contract_options(),
          @posoco.StreamMode::NoStream,
        ),
      ) catch {
        e => Err(e)
      }
    },
  )
  assert_eq(loopback.bodies.length(), 1)
  let value = contract_expect_success(result)
  assert_eq(
    value.completion.message.finish_reason,
    @posoco.FinishReason::Length,
  )
  assert_eq(value.completion.message.content.length(), 0)
}

///|
async test "contract nonstream HTTP error is classified and redacted" {
  let secret = "secret-provider-body"
  let (result, loopback) = contract_with_loopback(
    [{ status: 500, body: secret, }],
    (base_url, _loopback) => {
      let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
        "sk-test",
        base_url~,
      )
      let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
        config,
      )
      let port : &@posoco.ModelPort = port_impl
      Ok(
        port.chat(
          contract_scope(),
          contract_messages(),
          [],
          contract_options(),
          @posoco.StreamMode::NoStream,
        ),
      ) catch {
        e => Err(e)
      }
    },
  )
  assert_eq(loopback.paths, ["/chat/completions"])
  let message = contract_expect_transport(result)
  assert_true(message.contains("stage=chat.http_status"))
  assert_true(message.contains("status=500"))
  assert_true(message.contains("body_bytes=\{secret.length()}"))
  assert_true(message.contains("body_category=utf8"))
  assert_false(message.contains(secret))
}

///|
async test "contract nonstream effort off disables thinking on the wire" {
  let (result, loopback) = contract_with_loopback(
    [LoopbackReply::ok(contract_response_body("stop", "plain"))],
    (base_url, _loopback) => {
      let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
        "sk-test",
        base_url~,
        reasoning_effort="",
      )
      let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
        config,
      )
      let port : &@posoco.ModelPort = port_impl
      Ok(
        port.chat(
          contract_scope(),
          contract_messages(),
          [],
          contract_options(),
          @posoco.StreamMode::NoStream,
        ),
      ) catch {
        e => Err(e)
      }
    },
  )
  assert_eq(loopback.bodies.length(), 1)
  let body = loopback.bodies[0]
  assert_eq(
    contract_body_field(body, "thinking"),
    Some(Json::object({ "type": Json::string("disabled") })),
  )
  assert_eq(contract_body_field(body, "reasoning_effort"), None)
  let value = contract_expect_success(result)
  assert_true(
    value.completion.message.content[0] is @posoco.Content::Text("plain"),
  )
}

///|
async test "contract stream chat forwards each chunk exactly once and completes" {
  let sse = contract_sse([
    contract_reasoning_chunk("thinking "),
    contract_text_chunk("Hello"),
    contract_finish_chunk(),
    "[DONE]",
  ])
  let chunks : Array[@posoco.StreamChunk] = []
  let (result, loopback) = contract_with_loopback([LoopbackReply::ok(sse)], (
    base_url,
    _loopback,
  ) => {
    let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
      "sk-test",
      base_url~,
    )
    let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
      config,
    )
    let port : &@posoco.ModelPort = port_impl
    Ok(
      port.chat(
        contract_scope(),
        contract_messages(),
        [],
        contract_options(),
        @posoco.StreamMode::Stream(fn(chunk) { chunks.push(chunk) }),
      ),
    ) catch {
      e => Err(e)
    }
  })
  assert_eq(loopback.paths, ["/chat/completions"])
  let body = loopback.bodies[0]
  assert_eq(contract_body_field(body, "stream"), Some(Json::boolean(true)))
  assert_eq(
    contract_body_field(body, "stream_options"),
    Some(Json::object({ "include_usage": Json::boolean(true) })),
  )
  let value = contract_expect_success(result)
  // Each wire event surfaces exactly once, in arrival order.
  assert_eq(chunks.length(), 4)
  assert_eq(chunks[0], @posoco.StreamChunk::ReasoningDelta(token="thinking "))
  assert_eq(chunks[1], @posoco.StreamChunk::TextDelta(token="Hello"))
  assert_true(
    chunks[2]
    is @posoco.StreamChunk::Usage(
      input_tokens=5,
      output_tokens=2,
      total_tokens=7,
      ..
    ),
  )
  assert_eq(chunks[3], @posoco.StreamChunk::Finish(reason="stop"))
  assert_true(
    value.completion.message.content[0] is @posoco.Content::Text("Hello"),
  )
  assert_eq(value.completion.message.finish_reason, @posoco.FinishReason::Stop)
  assert_eq(
    value.completion.message.reasoning,
    Some(@posoco.Reasoning::{ content: "thinking ", raw: None, }),
  )
  guard value.completion.usage is Some(usage) else {
    fail("stream completion must carry the reported usage")
  }
  assert_eq(usage.total_tokens, Some(7))
}

///|
async test "contract stream early EOF without a terminal marker raises a parse error" {
  // The SSE body ends cleanly (the HTTP body is complete) before any
  // finish_reason or [DONE]: the stream is truncated at the protocol level.
  let sse = contract_sse([
    contract_reasoning_chunk("thinking "),
    contract_text_chunk("partial"),
  ])
  let chunks : Array[@posoco.StreamChunk] = []
  let (result, _loopback) = contract_with_loopback([LoopbackReply::ok(sse)], (
    base_url,
    _loopback,
  ) => {
    let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
      "sk-test",
      base_url~,
    )
    let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
      config,
    )
    let port : &@posoco.ModelPort = port_impl
    Ok(
      port.chat(
        contract_scope(),
        contract_messages(),
        [],
        contract_options(),
        @posoco.StreamMode::Stream(fn(chunk) { chunks.push(chunk) }),
      ),
    ) catch {
      e => Err(e)
    }
  })
  guard result is Err(@posoco.ModelError::ResponseParse(message)) else {
    fail("a truncated stream must never become a completion")
  }
  assert_true(message.contains("SSE truncated"))
  assert_true(message.contains("stage=eof"))
  // The observed deltas were still forwarded; nothing fabricated afterwards.
  assert_eq(chunks.length(), 2)
}

///|
async test "contract stream HTTP error is classified and redacted" {
  let secret = "secret-provider-body"
  let (result, loopback) = contract_with_loopback(
    [{ status: 503, body: secret, }],
    (base_url, _loopback) => {
      let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
        "sk-test",
        base_url~,
      )
      let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
        config,
      )
      let port : &@posoco.ModelPort = port_impl
      Ok(
        port.chat(
          contract_scope(),
          contract_messages(),
          [],
          contract_options(),
          @posoco.StreamMode::Stream(fn(_chunk) { () }),
        ),
      ) catch {
        e => Err(e)
      }
    },
  )
  assert_eq(loopback.paths, ["/chat/completions"])
  let message = contract_expect_transport(result)
  assert_true(message.contains("stage=chat_stream.http_status"))
  assert_true(message.contains("status=503"))
  assert_true(message.contains("body_bytes=\{secret.length()}"))
  assert_false(message.contains(secret))
}

///|
async test "contract stream reasoning budget breach aborts with a transport error" {
  let sse = contract_sse([contract_reasoning_chunk("x".repeat(200)), "[DONE]"])
  let (result, _loopback) = contract_with_loopback([LoopbackReply::ok(sse)], (
    base_url,
    _loopback,
  ) => {
    let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
      "sk-test",
      base_url~,
      max_reasoning_chars=Some(128),
    )
    let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
      config,
    )
    let port : &@posoco.ModelPort = port_impl
    Ok(
      port.chat(
        contract_scope(),
        contract_messages(),
        [],
        contract_options(),
        @posoco.StreamMode::Stream(fn(_chunk) { () }),
      ),
    ) catch {
      e => Err(e)
    }
  })
  let message = contract_expect_transport(result)
  assert_true(message.contains("category=reasoning_budget_exceeded"))
}

///|
async test "contract stream repeated reasoning suffix aborts with a transport error" {
  let span = "r".repeat(128)
  let sse = contract_sse([
    contract_reasoning_chunk(span),
    contract_reasoning_chunk(span),
    contract_reasoning_chunk(span),
    "[DONE]",
  ])
  let (result, _loopback) = contract_with_loopback([LoopbackReply::ok(sse)], (
    base_url,
    _loopback,
  ) => {
    let config = @posoco-ext-deepseek.DeepSeekConfig::DeepSeekConfig(
      "sk-test",
      base_url~,
      repeated_reasoning_span_chars=Some(128),
    )
    let port_impl = @posoco-ext-deepseek.DeepSeekModelPort::DeepSeekModelPort(
      config,
    )
    let port : &@posoco.ModelPort = port_impl
    Ok(
      port.chat(
        contract_scope(),
        contract_messages(),
        [],
        contract_options(),
        @posoco.StreamMode::Stream(fn(_chunk) { () }),
      ),
    ) catch {
      e => Err(e)
    }
  })
  let message = contract_expect_transport(result)
  assert_true(message.contains("category=reasoning_repetition"))
}
