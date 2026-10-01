///|
/// Real loopback HTTP tests for the OpenAI compact endpoint (W3): the port
/// under test is the production `OpenAIModelPort::compact` driving
/// `openai_post_json` against an ephemeral in-process `@http.Server`. No
/// transport seam is added; the server is test-local.

///|
/// Scripted behavior for one accepted compact request.
priv enum CompactReply {
  /// Full HTTP response after an optional delay.
  Respond(
    status~ : Int,
    body~ : String,
    headers~ : Array[(String, String)],
    delay_ms~ : Int
  )
  /// Send a response head only and never deliver the body — the client stays
  /// parked in its body read.
  HeadThenHang
  /// Accept the request and never answer — the client stays parked waiting
  /// for the status line.
  Hang
  /// Send a head and a body fragment, then close mid-body.
  RespondTruncated(status~ : Int, partial~ : String)
}

///|
/// Loopback server recording requests and observing client disconnects.
struct CompactLoopback {
  server : @http.Server
  replies : Array[CompactReply]
  requests : Array[@http.Request]
  bodies : Array[String]
  mut next_reply : Int
  mut client_disconnected : Bool
  mut stopping : Bool
}

///|
/// Await-style attempt: binds a raising async call into a Result so each
/// server step can degrade explicitly.
async fn[T] attempt_async(f : async () -> T) -> Result[T, Error] {
  Ok(f()) catch {
    e => Err(e)
  }
}

///|
fn compact_body_text(data : Bytes) -> String {
  @utf8.decode_lossy(data[0:])
}

///|
async fn CompactLoopback::bind(
  replies : Array[CompactReply],
) -> CompactLoopback {
  // Ephemeral port via the transient-listener probe (same pattern as the
  // path-bearing base_url test): bind on 0, read the port, close, rebind.
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
    requests: [],
    bodies: [],
    next_reply: 0,
    client_disconnected: false,
    stopping: false,
  }
}

///|
/// Serve requests until stopped. Each request is answered from the reply
/// queue (the last reply repeats when the queue runs dry). After every
/// request the server waits for the client to disconnect, which is the
/// observable client-cleanup signal.
async fn CompactLoopback::serve(self : CompactLoopback) -> Unit {
  while !self.stopping {
    // Bound each accept so stop() always terminates the serve task.
    let accepted = attempt_async(() => {
      @async.with_timeout(200, () => self.server.accept())
    })
    let (conn, _) = match accepted {
      Ok(accepted) => accepted
      Err(_) => {
        if self.stopping {
          return
        }
        continue
      }
    }
    defer conn.close()
    let request = match attempt_async(() => conn.read_request()) {
      Ok(request) => request
      Err(_) => {
        conn.close()
        continue
      }
    }
    self.requests.push(request)
    // The ServerConnection reader decodes the request body framing
    // (chunked/content-length); read it through the @io.Reader API until the
    // body-end marker surfaces.
    let buf = StringBuilder()
    for i in 0..<64 {
      match attempt_async(() => conn.read_some()) {
        Ok(None) => break
        Ok(Some(data)) => buf.write_string(compact_body_text(data))
        Err(_) => break
      }
      let _ = i
    }
    self.bodies.push(buf.to_string())
    let reply = if self.replies.is_empty() {
      Hang
    } else {
      let index = if self.next_reply < self.replies.length() {
        self.next_reply
      } else {
        self.replies.length() - 1
      }
      self.next_reply += 1
      self.replies[index]
    }
    match reply {
      Respond(status~, body~, headers~, delay_ms~) => {
        if delay_ms > 0 {
          @async.sleep(delay_ms)
        }
        let header_pairs : Array[(String, String)] = [
          ("Content-Type", "application/json"),
        ]
        for entry in headers {
          header_pairs.push(entry)
        }
        let extra : @http.Headers = Map::from_array(
          header_pairs.map(fn(entry) {
            (@http.CaseInsensitiveString(entry.0), entry.1)
          }),
        )
        // send_response's String argument is the REASON phrase; the payload
        // is written through the @io.Writer, then the response is ended.
        let _ = attempt_async(() => {
          conn.send_response(status, "OK", extra_headers=extra)
        })
        let _ = attempt_async(() => conn.write_string(body))
        let _ = attempt_async(() => conn.end_response())
        conn.close()
      }
      HeadThenHang => {
        // Status + head go out; the body never does. The client parks in its
        // body read.
        let _ = attempt_async(() => conn.send_response(200, "OK"))
        let _ = attempt_async(() => conn.write_string("{\"output\":"))
        self.park_until_client_disconnect(conn)
      }
      Hang => self.park_until_client_disconnect(conn)
      RespondTruncated(status~, partial~) => {
        let _ = attempt_async(() => conn.send_response(status, "OK"))
        let _ = attempt_async(() => conn.write_string(partial))
        conn.close()
      }
    }
  }
}

///|
/// Wait for the next request head, not the already-consumed request body:
/// body EOF is not socket disconnect. Only a failed head read observes close;
/// the watchdog must never count as client cleanup.
async fn CompactLoopback::park_until_client_disconnect(
  self : CompactLoopback,
  conn : @http.ServerConnection,
) -> Unit {
  let step = attempt_async(() => {
    @async.with_timeout(10000, () => conn.read_request())
  })
  match step {
    Ok(_) => ()
    Err(@async.TimeoutError) => fail("client did not disconnect")
    Err(_) => self.client_disconnected = true
  }
  conn.close()
}

///|
fn CompactLoopback::stop(self : CompactLoopback) -> Unit {
  if self.stopping {
    return
  }
  self.stopping = true
  self.server.close()
}

///|
fn compact_loopback_port(base_url : String) -> OpenAIModelPort {
  OpenAIModelPort::OpenAIModelPort(
    OpenAIConfig::with_base_url("k-test", "gpt-5", base_url),
  )
}

///|
fn compact_loopback_scope() -> @posoco.InvocationScope {
  @posoco.InvocationScope::{
    session_id: @posoco.SessionId::unchecked("compact-loopback"),
    run_id: @posoco.RunId::unchecked("run-1"),
    effect_id: None,
    pressure: None,
  }
}

///|
fn compact_loopback_messages() -> Array[@posoco.Message] {
  [@posoco.Message::UserMessage(content=[@posoco.Content::Text("q1")])]
}

///|
/// Run one compact call against `reply` and return the outcome plus a
/// snapshot of what the server saw. Bounded so a regression fails instead of
/// hanging the suite.
async fn compact_loopback_call(
  reply : CompactReply,
) -> (Result[@posoco.CompactResult, @posoco.ModelError], CompactLoopback) {
  let results = @async.with_timeout(20000, () => {
    compact_loopback_call_many([reply])
  })
  (results.0[0], results.1)
}

///|
async fn compact_loopback_call_many(
  replies : Array[CompactReply],
) -> (Array[Result[@posoco.CompactResult, @posoco.ModelError]], CompactLoopback) {
  let outcomes : Array[Result[@posoco.CompactResult, @posoco.ModelError]] = []
  let loopback = CompactLoopback::bind(replies)
  @async.with_task_group() <| group => {
    let _ = group.spawn(() => loopback.serve(), allow_failure=true)
    let port = compact_loopback_port(
      "http://127.0.0.1:\{loopback.server.addr.port()}/v1",
    )
    for _reply in replies {
      let outcome = Ok(
        port.compact(
          compact_loopback_scope(),
          compact_loopback_messages(),
          { temperature: None, max_output_tokens: None, },
          @posoco.CompactTrigger::Manual,
        ),
      ) catch {
        e => Err(e)
      }
      outcomes.push(outcome)
    }
    loopback.stop()
  }
  (outcomes, loopback)
}

///|
test "openai_compact_default_deadline_matches_pinned_codex_policy" {
  assert_eq(openai_compact_deadline_ms, 300_000 * 4)
  assert_eq(openai_compact_deadline_ms, 1_200_000)
}

///|
async fn compact_deadline_loopback_retry(reply : CompactReply) -> Unit {
  let loopback = CompactLoopback::bind([
    reply,
    Respond(
      status=200,
      body="{\"output\":[{\"role\":\"user\",\"content\":\"q1\"}]}",
      headers=[],
      delay_ms=0,
    ),
  ])
  defer loopback.stop()
  @async.with_timeout(3000, () => {
    @async.with_task_group() <| group => {
      defer loopback.stop()
      let _ = group.spawn(() => loopback.serve(), allow_failure=true)
      let port = compact_loopback_port(
        "http://127.0.0.1:\{loopback.server.addr.port()}/v1",
      )
      let body = build_compact_request_body(
        compact_loopback_messages(),
        port.config.model,
      )
      let outcome = @async.with_timeout(1000, () => {
        Ok(
          openai_compact_post_json(
            port.config,
            body,
            Some("compact-loopback"),
            deadline_ms=100,
          ),
        ) catch {
          e => Err(e)
        }
      }) catch {
        @async.TimeoutError =>
          fail("outer test watchdog fired instead of compact deadline")
        err => raise err
      }
      guard outcome is Err(@posoco.ModelError::Transport(message)) else {
        fail("expected typed compact deadline Transport")
      }
      assert_eq(
        message, "OpenAI transport failure (stage=compact_deadline, category=timeout, deadline_ms=100)",
      )
      assert_eq(loopback.requests.length(), 1)
      @async.with_timeout(1000, () => {
        while !loopback.client_disconnected {
          @async.pause()
        }
      })
      // The failed request is not automatically retried. A new explicit
      // compact on the same ModelPort must still succeed.
      let retry = port.compact(
        compact_loopback_scope(),
        compact_loopback_messages(),
        { temperature: None, max_output_tokens: None, },
        @posoco.CompactTrigger::Manual,
      )
      assert_true(retry.mode is @posoco.CompactMode::Replace)
      assert_eq(loopback.requests.length(), 2)
    }
  })
}

///|
async test "openai_compact_deadline_during_status_wait_disconnects_and_retries" {
  compact_deadline_loopback_retry(Hang)
}

///|
async test "openai_compact_deadline_during_body_read_disconnects_and_retries" {
  compact_deadline_loopback_retry(HeadThenHang)
}

///|
async test "openai_compact_loopback_wire_shape_is_minimal_model_input" {
  let (result, loopback) = compact_loopback_call(
    Respond(
      status=200,
      body="{\"output\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"q1\"}]}]}",
      headers=[],
      delay_ms=0,
    ),
  )
  loopback.stop()
  guard result is Ok(compacted) else { fail("compact must succeed") }
  assert_true(compacted.mode is @posoco.CompactMode::Replace)
  assert_eq(loopback.requests.length(), 1)
  let request = loopback.requests[0]
  guard request.meth is @http.RequestMethod::Post else {
    fail("compact must POST")
  }
  assert_eq(request.path, "/v1/responses/compact")
  assert_eq(request.headers.get("Authorization"), Some("Bearer k-test"))
  assert_eq(request.headers.get("Content-Type"), Some("application/json"))
  match request.headers.get("User-Agent") {
    Some(ua) => assert_true(ua.has_prefix("posoco/ext-openai ("))
    None => fail("compact must send the posoco User-Agent")
  }
  assert_true(request.headers.get("originator") is None)
  assert_true(request.headers.get("session-id") is None)
  // The public compact request stays the official minimal {model, input}.
  guard @json.parse(loopback.bodies[0]) is Json::Object(fields) else {
    fail("request body must be a JSON object")
  }
  assert_eq(fields.length(), 2)
  assert_eq(fields.get("model"), Some(Json::string("gpt-5")))
  guard fields.get("input") is Some(Json::Array(items)) else {
    fail("request input must be an item array")
  }
  assert_eq(items.length(), 1)
}

///|
async test "openai_compact_loopback_success_replays_output_window" {
  let (result, loopback) = compact_loopback_call(
    Respond(
      status=200,
      body="{\"output\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"kept\"}]},{\"type\":\"compaction\",\"id\":\"cmp_1\",\"encrypted_content\":\"zzz\"}]}",
      headers=[],
      delay_ms=0,
    ),
  )
  loopback.stop()
  guard result is Ok(compacted) else { fail("compact must succeed") }
  // Anchor + retained user + synthetic state assistant.
  assert_eq(compacted.compacted_messages.length(), 3)
  assert_eq(loopback.bodies.length(), 1)
}

///|
/// Compact errors must carry safe, parseable diagnostics (stage, status,
/// allowlisted provider code/param/category, x-request-id) before the
/// redacted body summary — and never an arbitrary provider body excerpt.
async test "openai_compact_loopback_400_diagnostics_are_safe" {
  let (result, loopback) = compact_loopback_call(
    Respond(
      status=400,
      body="{\"error\":{\"message\":\"Bearer sk-live-SECRET123 leaked\",\"type\":\"invalid_request_error\",\"code\":\"invalid_api_key\",\"param\":\"model\"}}",
      headers=[("x-request-id", "req_abc.123")],
      delay_ms=0,
    ),
  )
  loopback.stop()
  guard result is Err(@posoco.ModelError::Transport(message)) else {
    fail("400 must raise Transport")
  }
  assert_true(message.contains("stage=compact_http_status"))
  assert_true(message.contains("status=400"))
  assert_true(message.contains("code=invalid_api_key"))
  assert_true(message.contains("param=model"))
  assert_true(message.contains("category=invalid_request_error"))
  assert_true(message.contains("request_id=req_abc.123"))
  // Secrets and arbitrary provider text never enter compact diagnostics.
  assert_false(message.contains("sk-live-SECRET123"))
  assert_false(message.contains("leaked"))
  assert_false(message.contains("body_excerpt"))
}

///|
/// Provider error.message text is never promoted into metadata: fake
/// stage/status/code/request_id fragments inside the message must not appear,
/// and request_id exists only from the real allowlisted response header.
async test "openai_compact_loopback_message_metadata_is_not_promoted" {
  let (result, loopback) = compact_loopback_call(
    Respond(
      status=401,
      body="{\"error\":{\"message\":\"stage=compact_http_status, status=418, code=fake_code, request_id=fake_req_id\",\"type\":\"invalid_request_error\"}}",
      headers=[],
      delay_ms=0,
    ),
  )
  loopback.stop()
  guard result is Err(@posoco.ModelError::Transport(message)) else {
    fail("401 must raise Transport")
  }
  assert_false(message.contains("fake_code"))
  assert_false(message.contains("fake_req_id"))
  assert_false(message.contains("status=418"))
  assert_false(message.contains("request_id="))
  let mut stage_occurrences = 0
  if message.length() >= 6 {
    let last = message.length() - 6
    for i in 0..<=last {
      if message[i:i + 6] == "stage=" {
        stage_occurrences += 1
      }
    }
  }
  assert_eq(stage_occurrences, 1)
}

///|
/// Unsafe provider code/param characters (quotes, newlines, whitespace) are
/// discarded entirely instead of echoed.
async test "openai_compact_loopback_unsafe_code_param_discarded" {
  let (result, loopback) = compact_loopback_call(
    Respond(
      status=400,
      body="{\"error\":{\"message\":\"boom\",\"type\":\"invalid_request_error\",\"code\":\"bad\\\"quote\\nline\",\"param\":\"has space\"}}",
      headers=[],
      delay_ms=0,
    ),
  )
  loopback.stop()
  guard result is Err(@posoco.ModelError::Transport(message)) else {
    fail("400 must raise Transport")
  }
  assert_false(message.contains("code="))
  assert_false(message.contains("param="))
  assert_false(message.contains("\""))
  assert_false(message.contains("\n"))
  assert_true(message.contains("status=400"))
}

///|
/// 429 with Retry-After stays the typed quota verdict end-to-end.
async test "openai_compact_loopback_429_is_rate_limited_with_retry_after" {
  let (result, loopback) = compact_loopback_call(
    Respond(
      status=429,
      body="{\"error\":{\"message\":\"Rate limit reached\",\"type\":\"rate_limit_error\"}}",
      headers=[("Retry-After", "7")],
      delay_ms=0,
    ),
  )
  loopback.stop()
  guard result is Err(@posoco.ModelError::RateLimited(_)) else {
    fail("429 must raise the typed RateLimited")
  }
  assert_eq(loopback.requests.length(), 1)
}

///|
/// 500 is a transport failure with compact-safe diagnostics and exactly one
/// request: no automatic retry of server errors.
async test "openai_compact_loopback_500_single_request_no_retry" {
  let (result, loopback) = compact_loopback_call(
    Respond(
      status=500,
      body="{\"error\":{\"message\":\"upstream explosion with credentials sk-live-SECRET\",\"type\":\"server_error\"}}",
      headers=[],
      delay_ms=0,
    ),
  )
  loopback.stop()
  guard result is Err(@posoco.ModelError::Transport(message)) else {
    fail("500 must raise Transport")
  }
  assert_true(message.contains("stage=compact_http_status"))
  assert_true(message.contains("status=500"))
  assert_true(message.contains("category=server_error"))
  assert_false(message.contains("sk-live-SECRET"))
  assert_false(message.contains("body_excerpt"))
  assert_eq(loopback.requests.length(), 1)
}

///|
async test "openai_compact_loopback_invalid_json_body_fails_loud" {
  let (result, loopback) = compact_loopback_call(
    Respond(status=200, body="not-json{", headers=[], delay_ms=0),
  )
  loopback.stop()
  guard result is Err(@posoco.ModelError::ResponseParse(message)) else {
    fail("invalid JSON must raise ResponseParse")
  }
  assert_true(message.contains("stage=json"))
}

///|
/// Missing/null output are protocol failures; an empty output stays an
/// empty-window failure. The window is never silently replaced.
async test "openai_compact_loopback_missing_null_empty_output_fail" {
  let (outcomes_all, loopback) = compact_loopback_call_many([
    Respond(
      status=200,
      body="{\"status\":\"completed\"}",
      headers=[],
      delay_ms=0,
    ),
    Respond(
      status=200,
      body="{\"output\":null,\"status\":\"completed\"}",
      headers=[],
      delay_ms=0,
    ),
    Respond(status=200, body="{\"output\":[]}", headers=[], delay_ms=0),
  ])
  loopback.stop()
  assert_eq(outcomes_all.length(), 3)
  for outcome in outcomes_all {
    guard outcome is Err(@posoco.ModelError::ResponseParse(message)) else {
      fail("degenerate outputs must raise ResponseParse")
    }
    assert_true(
      message.contains("category=missing_output") ||
      message.contains("category=empty_window"),
    )
  }
  assert_eq(loopback.requests.length(), 3)
}

///|
/// A connection closed mid-body fails loudly instead of reporting success,
/// and the same port stays usable for the next compact.
async test "openai_compact_loopback_premature_disconnect_fails_loud" {
  let loopback = CompactLoopback::bind([
    RespondTruncated(status=200, partial="{\"output\":[{\"role\":\"user\""),
    Respond(
      status=200,
      body="{\"output\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"q1\"}]}]}",
      headers=[],
      delay_ms=0,
    ),
  ])
  let outcomes : Array[Result[@posoco.CompactResult, @posoco.ModelError]] = []
  let step = @async.with_timeout(20000, () => {
    @async.with_task_group() <| group => {
      let _ = group.spawn(() => loopback.serve(), allow_failure=true)
      let port = compact_loopback_port(
        "http://127.0.0.1:\{loopback.server.addr.port()}/v1",
      )
      for _reply in loopback.replies {
        let outcome = Ok(
          port.compact(
            compact_loopback_scope(),
            compact_loopback_messages(),
            { temperature: None, max_output_tokens: None, },
            @posoco.CompactTrigger::Manual,
          ),
        ) catch {
          e => Err(e)
        }
        outcomes.push(outcome)
      }
      loopback.stop()
    }
    1
  }) catch {
    _ => 0
  }
  ignore(step)
  guard outcomes[0] is Err(_) else { fail("truncated body must fail loudly") }
  guard outcomes[1] is Ok(_) else {
    fail("retry after disconnect must succeed")
  }
}

///|
/// Cancellation while waiting for the status line: the in-flight request is
/// abandoned (no retry), the client socket is closed (server observes the
/// disconnect), and the same model port serves a fresh compact.
async test "openai_compact_loopback_cancel_during_status_wait_cleans_and_retries" {
  let loopback = CompactLoopback::bind([
    Hang,
    Respond(
      status=200,
      body="{\"output\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"q1\"}]}]}",
      headers=[],
      delay_ms=0,
    ),
  ])
  let step = @async.with_timeout(20000, () => {
    @async.with_task_group() <| group => {
      let _ = group.spawn(() => loopback.serve(), allow_failure=true)
      let port = compact_loopback_port(
        "http://127.0.0.1:\{loopback.server.addr.port()}/v1",
      )
      let task = group.spawn(
        () => {
          let _ = Ok(
            port.compact(
              compact_loopback_scope(),
              compact_loopback_messages(),
              { temperature: None, max_output_tokens: None, },
              @posoco.CompactTrigger::Manual,
            ),
          ) catch {
            e => Err(e)
          }
          ()
        },
        allow_failure=true,
      )
      while loopback.requests.length() < 1 {
        @async.pause()
      }
      task.cancel()
      let mut waited = 0
      while !loopback.client_disconnected && waited < 400 {
        @async.pause()
        waited += 1
      }
      assert_true(loopback.client_disconnected)
      assert_eq(loopback.requests.length(), 1)
      let retry = port.compact(
        compact_loopback_scope(),
        compact_loopback_messages(),
        { temperature: None, max_output_tokens: None, },
        @posoco.CompactTrigger::Manual,
      )
      let _ = retry
      loopback.stop()
    }
    1
  }) catch {
    _ => 0
  }
  if step == 0 {
    fail("cancellation scenario timed out")
  }
  assert_eq(loopback.requests.length(), 2)
}

///|
/// Cancellation while parked in the response-body read behaves the same:
/// single abandoned request, observed disconnect, successful retry.
async test "openai_compact_loopback_cancel_during_body_read_cleans_and_retries" {
  let loopback = CompactLoopback::bind([
    HeadThenHang,
    Respond(
      status=200,
      body="{\"output\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"q1\"}]}]}",
      headers=[],
      delay_ms=0,
    ),
  ])
  let step = @async.with_timeout(20000, () => {
    @async.with_task_group() <| group => {
      let _ = group.spawn(() => loopback.serve(), allow_failure=true)
      let port = compact_loopback_port(
        "http://127.0.0.1:\{loopback.server.addr.port()}/v1",
      )
      let task = group.spawn(
        () => {
          let _ = Ok(
            port.compact(
              compact_loopback_scope(),
              compact_loopback_messages(),
              { temperature: None, max_output_tokens: None, },
              @posoco.CompactTrigger::Manual,
            ),
          ) catch {
            e => Err(e)
          }
          ()
        },
        allow_failure=true,
      )
      while loopback.requests.length() < 1 {
        @async.pause()
      }
      task.cancel()
      let mut waited = 0
      while !loopback.client_disconnected && waited < 400 {
        @async.pause()
        waited += 1
      }
      assert_true(loopback.client_disconnected)
      assert_eq(loopback.requests.length(), 1)
      let retry = port.compact(
        compact_loopback_scope(),
        compact_loopback_messages(),
        { temperature: None, max_output_tokens: None, },
        @posoco.CompactTrigger::Manual,
      )
      let _ = retry
      loopback.stop()
    }
    1
  }) catch {
    _ => 0
  }
  if step == 0 {
    fail("cancellation scenario timed out")
  }
  assert_eq(loopback.requests.length(), 2)
}
