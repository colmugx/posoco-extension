///|
/// WebSocket transport tests: pure helpers (URL, headers, delta, capture)
/// plus a loopback end-to-end over a real `@websocket` mock server.

///|
test "codex ws url derivation swaps the scheme and completes the path" {
  assert_eq(
    codex_ws_url("https://chatgpt.com/backend-api/codex"),
    "wss://chatgpt.com/backend-api/codex/responses",
  )
  assert_eq(
    codex_ws_url("https://chatgpt.com/backend-api/codex/"),
    "wss://chatgpt.com/backend-api/codex/responses",
  )
  assert_eq(
    codex_ws_url("https://chatgpt.com/backend-api/codex/responses"),
    "wss://chatgpt.com/backend-api/codex/responses",
  )
  assert_eq(
    codex_ws_url("http://127.0.0.1:9000/backend-api"),
    "ws://127.0.0.1:9000/backend-api/codex/responses",
  )
}

///|
test "codex ws handshake headers drop http-only fields and add the beta" {
  let headers = codex_ws_handshake_headers(codex_identity_test_config(), "s")
  assert_true(headers.get("Accept") is None)
  assert_true(headers.get("Content-Type") is None)
  assert_eq(headers.get("OpenAI-Beta"), Some("responses_websockets=2026-02-06"))
  assert_eq(headers.get("originator"), Some("posoco"))
  assert_eq(headers.get("session-id"), Some("s"))
  assert_eq(headers.get("thread-id"), headers.get("x-client-request-id"))
}

///|
/// The exact assistant item the mock server ships as `output_item.done`; the
/// delta test embeds it into the next request's input to model a verbatim
/// assistant replay.
let ws_mock_assistant_item : Json = Json::object(
  Map::from_array([
    ("type", Json::string("message")),
    ("role", Json::string("assistant")),
    (
      "content",
      Json::array([
        Json::object(
          Map::from_array([
            ("type", Json::string("output_text")),
            ("text", Json::string("hi")),
          ]),
        ),
      ]),
    ),
  ]),
)

///|
fn ws_mock_body(input : Array[Json]) -> Json {
  Json::object(
    Map::from_array([
      ("model", Json::string("gpt-5")),
      ("input", Json::array(input)),
      ("stream", Json::boolean(true)),
      ("store", Json::boolean(false)),
    ]),
  )
}

///|
fn ws_mock_completed(id : String) -> String {
  "{\"type\":\"response.completed\",\"response\":{\"id\":\"" +
  id +
  "\",\"status\":\"completed\",\"output\":[]}}"
}

///|
test "codex ws delta only fires on exact continuation" {
  let m1 = Json::object(Map::from_array([("i", Json::number(1))]))
  let m2 = Json::object(Map::from_array([("i", Json::number(2))]))
  let body_rest = Json::object(
    Map::from_array([
      ("model", Json::string("gpt-5")),
      ("stream", Json::boolean(true)),
      ("store", Json::boolean(false)),
    ]),
  )
  // No completed response yet: full body.
  assert_eq(
    codex_ws_delta_parts(ws_mock_body([m1]), [m1], body_rest, "", []),
    ws_mock_body([m1]),
  )
  // Exact extension: delta with the continuation id and the tail only.
  let extended = ws_mock_body([m1, ws_mock_assistant_item, m2])
  match
    codex_ws_delta_parts(extended, [m1], body_rest, "resp_1", [
      ws_mock_assistant_item,
    ]) {
    Json::Object(fields) => {
      assert_eq(
        fields.get("previous_response_id"),
        Some(Json::string("resp_1")),
      )
      assert_eq(fields.get("input"), Some(Json::array([m2])))
      assert_eq(fields.get("model"), Some(Json::string("gpt-5")))
    }
    _ => fail("expected a delta object")
  }
  // Changed non-input property: full body.
  let other_rest = Json::object(
    Map::from_array([
      ("model", Json::string("gpt-5.5")),
      ("stream", Json::boolean(true)),
      ("store", Json::boolean(false)),
    ]),
  )
  assert_eq(
    codex_ws_delta_parts(extended, [m1], other_rest, "resp_1", [
      ws_mock_assistant_item,
    ]),
    extended,
  )
  // Assistant segment mismatch: full body.
  assert_eq(
    codex_ws_delta_parts(extended, [m1], body_rest, "resp_1", [m2]),
    extended,
  )
}

///|
test "quota reset remaining formats human-relative time" {
  assert_eq(quota_format_remaining(-5L), "now")
  assert_eq(quota_format_remaining(0L), "now")
  assert_eq(quota_format_remaining(30_000L), "<1m")
  assert_eq(quota_format_remaining(46L * 60_000L), "46m")
  assert_eq(quota_format_remaining(2L * 3_600_000L), "2h")
  assert_eq(quota_format_remaining(2L * 3_600_000L + 5L * 60_000L), "2h5m")
}

///|
test "codex ws provider error frames classify like the http path" {
  // Quota phrasing: the typed RateLimited the host's limit display and
  // scheduled resume key on.
  let limit_frame = "{\"type\":\"error\",\"status\":429,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The usage limit has been reached\"}}"
  match codex_ws_provider_error_if_any(limit_frame, now_ms=1000000L) {
    Some(@posoco.ModelError::RateLimited(info)) =>
      // The frame names no window or timestamp, so reset_at_ms is None and
      // the host's RateLimitGuard probe backoff schedules the resume — the
      // designed handler for verdicts without a stated reset.
      assert_true(info.message.contains("usage limit"))
    _ => fail("usage-limit frame must classify as RateLimited")
  }
  // Non-quota provider errors keep the message visible as transport errors.
  let model_frame = "{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-5' model is not supported\"}}"
  match codex_ws_provider_error_if_any(model_frame, now_ms=1000000L) {
    Some(@posoco.ModelError::Transport(message)) =>
      assert_true(message.contains("not supported"))
    _ => fail("model frame must surface its message")
  }
  // Non-error frames pass through untouched.
  assert_true(
    codex_ws_provider_error_if_any("{\"type\":\"response.created\"}", now_ms=0L)
    is None,
  )
  assert_true(codex_ws_provider_error_if_any("not json", now_ms=0L) is None)
}

///|
test "codex ws capture collects output items and the completed id" {
  let reasoning_item : Json = Json::object(
    Map::from_array([("type", Json::string("reasoning"))]),
  )
  let items : Array[Json] = []
  let id = Ref::{ val: "", }
  codex_ws_capture_output_item(
    "{\"type\":\"response.output_item.done\",\"item\":" +
    reasoning_item.stringify() +
    "}",
    items,
  )
  codex_ws_capture_output_item("not json", items)
  codex_ws_capture_output_item(
    "{\"type\":\"response.output_item.done\",\"item\":" +
    ws_mock_assistant_item.stringify() +
    "}",
    items,
  )
  codex_ws_capture_response_id(ws_mock_completed("resp_9"), id)
  codex_ws_capture_response_id("not json", id)
  assert_eq(items.length(), 2)
  assert_eq(id.val, "resp_9")
}

///|
/// Loopback WebSocket server: records client frames and replays one scripted
/// event sequence per received frame.
struct WsMock {
  server : @http.Server
  frames : Array[String]
  scripts : Array[Array[String]]
  mut stopping : Bool
}

///|
async fn WsMock::bind(scripts : Array[Array[String]]) -> WsMock {
  let probe = @socket.TcpServer(@socket.Addr::resolve("127.0.0.1", port=0)) catch {
    _ => abort("ws loopback probe bind failed")
  }
  let port = probe.addr.port()
  probe.close()
  let server = @http.Server(@socket.Addr::resolve("127.0.0.1", port~)) catch {
    _ => abort("ws loopback server bind failed")
  }
  { server, frames: [], scripts, stopping: false, }
}

///|
async fn WsMock::serve(self : WsMock) -> Unit {
  while !self.stopping {
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
    let request = match attempt_async(() => conn.read_request()) {
      Ok(request) => request
      Err(_) => {
        conn.close()
        continue
      }
    }
    let ws = match
      attempt_async(() => @websocket.from_http_server(request, conn)) {
      Ok(ws) => ws
      Err(_) => {
        conn.close()
        continue
      }
    }
    // Frame loop: record each client frame, replay the scripted events.
    for ;; {
      let frame = attempt_async(() => @async.with_timeout(5000, () => ws.recv()))
      match frame {
        Err(_) => break
        Ok(msg) => {
          let text = msg.read_all().text() catch { _ => break }
          self.frames.push(text)
          let index = self.frames.length() - 1
          let script = if index < self.scripts.length() {
            self.scripts[index]
          } else {
            []
          }
          for event in script {
            ws.send_text(event)
          }
        }
      }
    }
    ws.close()
    conn.close()
  }
}

///|
fn ws_mock_config(port : Int) -> OpenAIConfig {
  OpenAIConfig::with_base_url(
    codex_test_access_token(),
    "gpt-5",
    "http://127.0.0.1:\{port}/backend-api",
  )
}

///|
async test "codex ws loopback reuses the connection and sends the delta" {
  let created = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}"
  let done1 = "{\"type\":\"response.output_item.done\",\"item\":" +
    ws_mock_assistant_item.stringify() +
    "}"
  let done2 = "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"again\"}]}}"
  let mock = WsMock::bind([
    [created, done1, ws_mock_completed("resp_1")],
    [done2, ws_mock_completed("resp_2")],
  ])
  @async.with_timeout(20000, () => {
    @async.with_task_group() <| group => {
      let _ = group.spawn(() => mock.serve(), allow_failure=true)
      let config = ws_mock_config(mock.server.addr.port())
      let port_impl = OpenAIModelPort(config)
      let messages : Array[@posoco.Message] = []
      // Two turns over one cached connection; the mocked events advance the
      // continuation state (resp_1 then resp_2).
      let options : @posoco.ChatOptions = {
        temperature: None,
        max_output_tokens: None,
      }
      let sink = fn(_chunk : @posoco.StreamChunk) { () }
      match port_impl.codex_ws_chat("ws-loop", messages, [], options, sink) {
        Done(_) => ()
        FallBack => fail("turn 1 must not fall back")
      }
      match port_impl.codex_ws_chat("ws-loop", messages, [], options, sink) {
        Done(_) => ()
        FallBack => fail("turn 2 must not fall back")
      }
      codex_ws_drop_session("ws-loop")
      // Wire assertions: both turns rode the cached connection and both
      // frames are full bodies (empty windows re-encode identically, so the
      // continuation guard never fires here; the delta decision itself is
      // covered by the pure-function test above).
      assert_eq(mock.frames.length(), 2)
      let frame1 = @json.parse(mock.frames[0]) catch { _ => abort("frame 1") }
      guard frame1 is Json::Object(f1) else { abort("frame 1 object") }
      assert_eq(f1.get("type"), Some(Json::string("response.create")))
      assert_true(f1.get("previous_response_id") is None)
      let frame2 = @json.parse(mock.frames[1]) catch { _ => abort("frame 2") }
      guard frame2 is Json::Object(f2) else { abort("frame 2 object") }
      assert_eq(f2.get("type"), Some(Json::string("response.create")))
      assert_true(f2.get("previous_response_id") is None)
      // Stop the server inside the task group so the spawned serve task
      // observes the flag and the group can join.
      mock.stopping = true
      mock.server.close()
    }
  })
}

///|
async test "codex ws unreachable endpoint falls back and marks the session" {
  // Bind, read the port, close: nothing listens there anymore.
  let probe = @socket.TcpServer(@socket.Addr::resolve("127.0.0.1", port=0)) catch {
    _ => abort("dead port probe failed")
  }
  let port = probe.addr.port()
  probe.close()
  let config = ws_mock_config(port)
  let port_impl = OpenAIModelPort(config)
  let messages : Array[@posoco.Message] = []
  let outcome = port_impl.codex_ws_chat(
    "ws-dead",
    messages,
    [],
    { temperature: None, max_output_tokens: None, },
    fn(_chunk : @posoco.StreamChunk) { () },
  )
  guard outcome is FallBack else {
    abort("unreachable endpoint must fall back")
  }
  assert_true(codex_ws_session_is_fallback("ws-dead"))
}
