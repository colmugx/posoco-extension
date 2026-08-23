///|
/// One scripted transport outcome: a decoded response or a request-level
/// failure.
enum ScriptedReply {
  Reply(Int, Json)
  Fail(String)
}

///|
/// NmemTransport fake (plan D7): replies pop off `script` in order, every
/// received (url, body) pair is recorded for assertions, and a call past the
/// end of the script aborts — each flush must issue exactly its expected
/// requests.
struct FakeNmemTransport {
  script : Array[ScriptedReply]
  mut next : Int
  requests : Array[(String, Json)]
}

///|
fn FakeNmemTransport::FakeNmemTransport(
  script : Array[ScriptedReply],
) -> FakeNmemTransport {
  { script, next: 0, requests: [] }
}

///|
impl NmemTransport for FakeNmemTransport with fn post_json(
  self : FakeNmemTransport,
  url : String,
  _headers : Map[String, String],
  body : Json,
  timeout_ms~ : Int,
) -> Result[NmemResponse, String] {
  ignore(timeout_ms)
  self.requests.push((url, body))
  if self.next >= self.script.length() {
    abort("unexpected request")
  }
  let reply = self.script[self.next]
  self.next = self.next + 1
  match reply {
    Reply(status, body_json) => Ok({ status, body: body_json })
    Fail(message) => Err(message)
  }
}

///|
/// A lane that has never talked to the server.
fn fresh_lane() -> LaneState {
  { created: false, acknowledged: None, last_error: None, pending: None }
}

///|
/// Assemble a SyncRequest directly (tests control messages and config without
/// going through build_sync_request).
fn sync_request(
  messages? : Array[NmemThreadMessage] = [
    delta_msg(User, "hello", "e0"),
    delta_msg(Assistant, "hi there", "e1"),
  ],
  config? : NmemConfig = lane_config(),
  session_id? : String = "s1",
) -> SyncRequest {
  let tid = thread_id(config.source_app, session_id)
  {
    lane_key: sync_lane_key(tid, config),
    thread_id: tid,
    session_id,
    body: build_thread_body(
      thread_id=tid,
      title=thread_title(messages, config.source_app),
      messages~,
      config~,
      session_id~,
      sync_reason="agent_end",
    ),
    messages,
    config,
    sync_reason: "agent_end",
  }
}

///|
/// AckedCursor covering the first `upto` entries of `messages`.
fn cursor_over(messages : Array[NmemThreadMessage], upto : Int) -> AckedCursor {
  {
    count: upto,
    remote_count: upto,
    last_external_id: Some(message_external_id(messages[upto - 1])),
    prefix_fingerprint: prefix_fingerprint(messages, upto),
  }
}

///|
async test "flush_once: create ack acknowledges the whole transcript" {
  let transport = FakeNmemTransport::FakeNmemTransport([
    Reply(
      200,
      j("{\"thread\":{\"thread_id\":\"posoco-s1\",\"message_count\":2}}"),
    ),
  ])
  let request = sync_request()
  let result = flush_once(transport, request, fresh_lane(), timeout_ms=1000)
  inspect(result.created, content="true")
  guard result.acknowledged is Some(acked) else {
    fail("expected an acknowledged cursor")
  }
  let expected : AckedCursor = {
    ..cursor_over(request.messages, 2),
    remote_count: 2,
  }
  inspect(acked == expected, content="true")
  inspect(result.last_error is None, content="true")
  inspect(result.pending is None, content="true")
  inspect(transport.requests.length(), content="1")
  let (url, _) = transport.requests[0]
  inspect(url, content="http://127.0.0.1:14242/threads")
}

///|
async test "flush_once: create ok without a create ack keeps the lane uncreated" {
  let transport = FakeNmemTransport::FakeNmemTransport([
    Reply(
      200,
      j("{\"thread\":{\"thread_id\":\"other-thread\",\"message_count\":5}}"),
    ),
  ])
  let result = flush_once(
    transport,
    sync_request(),
    fresh_lane(),
    timeout_ms=1000,
  )
  inspect(result.created, content="false")
  inspect(result.acknowledged is None, content="true")
  guard result.last_error is Some(error) else { fail("expected a last_error") }
  inspect(error, content="thread sync did not receive a create acknowledgement")
}

///|
async test "flush_once: create 409 already exists falls through to a plain append" {
  let transport = FakeNmemTransport::FakeNmemTransport([
    Reply(409, j("{\"error\":\"thread already exists in space\"}")),
    Reply(
      200,
      j("{\"success\":true,\"messages_added\":2,\"total_messages\":2}"),
    ),
  ])
  let request = sync_request()
  let result = flush_once(transport, request, fresh_lane(), timeout_ms=1000)
  inspect(result.created, content="true")
  guard result.acknowledged is Some(acked) else {
    fail("expected an acknowledged cursor")
  }
  let expected : AckedCursor = {
    ..cursor_over(request.messages, 2),
    remote_count: 2,
  }
  inspect(acked == expected, content="true")
  inspect(transport.requests.length(), content="2")
  let (create_url, _) = transport.requests[0]
  inspect(create_url, content="http://127.0.0.1:14242/threads")
  let (append_url, append_json) = transport.requests[1]
  inspect(append_url, content="http://127.0.0.1:14242/threads/posoco-s1/append")
  // No cursor existed, so the append carries no checkpoint expectation.
  inspect(
    json_field(append_json, "expected_message_count") is None,
    content="true",
  )
  guard json_field(append_json, "idempotency_key") is Some(Json::String(key)) else {
    fail("expected an idempotency key")
  }
  inspect(
    key,
    content="posoco:s1:0-2:\{prefix_fingerprint(request.messages, 2)}",
  )
}

///|
async test "flush_once: cursor checkpoint append carries expected_message_count" {
  let messages = [
    delta_msg(User, "q1", "e0"),
    delta_msg(Assistant, "a1", "e1"),
    delta_msg(User, "q2", "e2"),
    delta_msg(Assistant, "a2", "e3"),
  ]
  let transport = FakeNmemTransport::FakeNmemTransport([
    Reply(
      200,
      j(
        "{\"success\":true,\"messages_added\":2,\"total_messages\":9,\"append_mode\":\"checkpointed\"}",
      ),
    ),
  ])
  let request = sync_request(messages~)
  let cursor : AckedCursor = { ..cursor_over(messages, 2), remote_count: 5 }
  let state : LaneState = {
    ..fresh_lane(),
    created: true,
    acknowledged: Some(cursor),
  }
  let result = flush_once(transport, request, state, timeout_ms=1000)
  inspect(result.created, content="true")
  guard result.acknowledged is Some(acked) else {
    fail("expected an acknowledged cursor")
  }
  let expected : AckedCursor = { ..cursor_over(messages, 4), remote_count: 9 }
  inspect(acked == expected, content="true")
  inspect(transport.requests.length(), content="1")
  let (url, body) = transport.requests[0]
  inspect(url, content="http://127.0.0.1:14242/threads/posoco-s1/append")
  guard json_field(body, "idempotency_key") is Some(Json::String(key)) else {
    fail("expected an idempotency key")
  }
  inspect(key, content="posoco:s1:2-4:\{prefix_fingerprint(messages, 4)}")
  guard json_field(body, "expected_message_count")
    is Some(Json::Number(value, ..)) else {
    fail("expected an expected_message_count")
  }
  inspect(value, content="5")
}

///|
async test "flush_once: checkpoint conflict retries the full transcript as reconcile" {
  let messages = [
    delta_msg(User, "q1", "e0"),
    delta_msg(Assistant, "a1", "e1"),
    delta_msg(User, "q2", "e2"),
    delta_msg(Assistant, "a2", "e3"),
  ]
  let transport = FakeNmemTransport::FakeNmemTransport([
    Reply(409, j("{\"error_code\":\"checkpoint_conflict\"}")),
    Reply(
      200,
      j("{\"success\":true,\"messages_added\":4,\"total_messages\":12}"),
    ),
  ])
  let request = sync_request(messages~)
  let cursor : AckedCursor = { ..cursor_over(messages, 2), remote_count: 5 }
  let state : LaneState = {
    ..fresh_lane(),
    created: true,
    acknowledged: Some(cursor),
  }
  let result = flush_once(transport, request, state, timeout_ms=1000)
  inspect(transport.requests.length(), content="2")
  let (_, retry_body) = transport.requests[1]
  guard json_field(retry_body, "messages") is Some(Json::Array(items)) else {
    fail("expected the full messages array")
  }
  inspect(items.length(), content="4")
  guard json_field(retry_body, "idempotency_key") is Some(Json::String(key)) else {
    fail("expected a reconcile idempotency key")
  }
  inspect(key, content="posoco:s1:reconcile:\{prefix_fingerprint(messages, 4)}")
  inspect(
    json_field(retry_body, "expected_message_count") is None,
    content="true",
  )
  guard result.acknowledged is Some(acked) else {
    fail("expected an acknowledged cursor")
  }
  let expected : AckedCursor = { ..cursor_over(messages, 4), remote_count: 12 }
  inspect(acked == expected, content="true")
}

///|
async test "flush_once: append 404 recreates the thread via the create body" {
  let messages = [
    delta_msg(User, "q1", "e0"),
    delta_msg(Assistant, "a1", "e1"),
    delta_msg(User, "q2", "e2"),
  ]
  let transport = FakeNmemTransport::FakeNmemTransport([
    Reply(404, j("{\"error_code\":\"thread_not_found\"}")),
    Reply(
      200,
      j("{\"thread\":{\"thread_id\":\"posoco-s1\",\"message_count\":3}}"),
    ),
  ])
  let request = sync_request(messages~)
  let state : LaneState = {
    ..fresh_lane(),
    created: true,
    acknowledged: Some(cursor_over(messages, 2)),
  }
  let result = flush_once(transport, request, state, timeout_ms=1000)
  inspect(transport.requests.length(), content="2")
  let (recreate_url, recreate_body) = transport.requests[1]
  inspect(recreate_url, content="http://127.0.0.1:14242/threads")
  inspect(recreate_body.stringify() == request.body.stringify(), content="true")
  inspect(result.created, content="true")
  guard result.acknowledged is Some(acked) else {
    fail("expected an acknowledged cursor")
  }
  let expected : AckedCursor = { ..cursor_over(messages, 3), remote_count: 3 }
  inspect(acked == expected, content="true")
}

///|
async test "flush_once: transport error keeps created state and the old cursor" {
  let messages = [
    delta_msg(User, "q1", "e0"),
    delta_msg(Assistant, "a1", "e1"),
    delta_msg(User, "q2", "e2"),
  ]
  let transport = FakeNmemTransport::FakeNmemTransport([
    Fail("connection refused"),
  ])
  let request = sync_request(messages~)
  let cursor = cursor_over(messages, 2)
  let state : LaneState = {
    ..fresh_lane(),
    created: true,
    acknowledged: Some(cursor),
  }
  let result = flush_once(transport, request, state, timeout_ms=1000)
  inspect(result.created, content="true")
  inspect(result.acknowledged == Some(cursor), content="true")
  guard result.last_error is Some(error) else { fail("expected a last_error") }
  inspect(error, content="thread sync failed (0): connection refused")
  inspect(transport.requests.length(), content="1")
  let (url, _) = transport.requests[0]
  inspect(url, content="http://127.0.0.1:14242/threads/posoco-s1/append")
}

///|
async test "flush_once: remote-api fallback origins are tried on 404 and on transport failure" {
  let remote = lane_config(api_url="https://mem.example.com/remote-api")
  let transport = FakeNmemTransport::FakeNmemTransport([
    Reply(404, j("{\"error\":\"not found\"}")),
    Reply(
      200,
      j("{\"thread\":{\"thread_id\":\"posoco-s1\",\"message_count\":2}}"),
    ),
  ])
  let request = sync_request(config=remote)
  let result = flush_once(transport, request, fresh_lane(), timeout_ms=1000)
  inspect(result.created, content="true")
  inspect(transport.requests.length(), content="2")
  let (primary_url, _) = transport.requests[0]
  inspect(primary_url, content="https://mem.example.com/remote-api/threads")
  let (fallback_url, _) = transport.requests[1]
  inspect(fallback_url, content="https://mem.example.com/threads")
  // A transport-level failure also advances to the fallback origin.
  let broken = FakeNmemTransport::FakeNmemTransport([
    Fail("dns broke"),
    Reply(
      200,
      j("{\"thread\":{\"thread_id\":\"posoco-s1\",\"message_count\":2}}"),
    ),
  ])
  let second = sync_request(config=remote)
  let recovered = flush_once(broken, second, fresh_lane(), timeout_ms=1000)
  inspect(recovered.created, content="true")
  inspect(broken.requests.length(), content="2")
}

///|
test "build_sync_request: None without an assistant message" {
  let request = build_sync_request(
    [user_message([@posoco.Content::Text("hello")])],
    session_id="s1",
    config=lane_config(),
    sync_reason="agent_end",
  )
  inspect(request is None, content="true")
}

///|
test "build_sync_request: full request for a syncable transcript" {
  let request = build_sync_request(
    [
      user_message([@posoco.Content::Text("hello")]),
      assistant_message([@posoco.Content::Text("hi")], []),
    ],
    session_id="s1",
    config=lane_config(),
    sync_reason="agent_end",
  )
  guard request is Some(payload) else { fail("expected a request") }
  inspect(payload.thread_id, content="posoco-s1")
  inspect(payload.session_id, content="s1")
  inspect(payload.sync_reason, content="agent_end")
  inspect(payload.messages.length(), content="2")
  inspect(
    payload.lane_key == sync_lane_key("posoco-s1", lane_config()),
    content="true",
  )
  json_inspect(payload.body, content={
    "thread_id": "posoco-s1",
    "title": "hello",
    "messages": [
      {
        "role": "user",
        "content": "hello",
        "metadata": { "external_id": "posoco-s1-0", "source_app": "posoco" },
      },
      {
        "role": "assistant",
        "content": "hi",
        "metadata": { "external_id": "posoco-s1-1", "source_app": "posoco" },
      },
    ],
    "source": "posoco",
    "project": null,
    "tool_version": "posoco-ext-nowledge-mem/0.1.0",
    "metadata": { "session_id": "s1", "sync_reason": "agent_end" },
  })
}

///|
test "resolve_thread_sync_timeout_ms: blank, garbage, and non-positive input fall back to the default" {
  inspect(resolve_thread_sync_timeout_ms(None), content="120000")
  inspect(resolve_thread_sync_timeout_ms(Some("")), content="120000")
  inspect(resolve_thread_sync_timeout_ms(Some("   ")), content="120000")
  inspect(resolve_thread_sync_timeout_ms(Some("soon")), content="120000")
  inspect(resolve_thread_sync_timeout_ms(Some("0")), content="120000")
  inspect(resolve_thread_sync_timeout_ms(Some("-5000")), content="120000")
  inspect(resolve_thread_sync_timeout_ms(Some("1.5")), content="120000")
}

///|
test "resolve_thread_sync_timeout_ms: valid values pass through and clamp at both ends" {
  inspect(resolve_thread_sync_timeout_ms(Some("1000")), content="1000")
  inspect(resolve_thread_sync_timeout_ms(Some("60000")), content="60000")
  inspect(resolve_thread_sync_timeout_ms(Some("1e3")), content="1000")
  inspect(resolve_thread_sync_timeout_ms(Some("10")), content="1000")
  inspect(resolve_thread_sync_timeout_ms(Some("999999999")), content="1800000")
}

///|
async test "SyncEngine: mark_dirty keeps the latest pending; drain_once flushes and clears it" {
  let transport = FakeNmemTransport::FakeNmemTransport([
    Reply(
      200,
      j("{\"thread\":{\"thread_id\":\"posoco-s1\",\"message_count\":4}}"),
    ),
  ])
  let engine = SyncEngine::new()
  let stale = sync_request()
  let latest = sync_request(messages=[
    delta_msg(User, "q1", "e0"),
    delta_msg(Assistant, "a1", "e1"),
    delta_msg(User, "q2", "e2"),
    delta_msg(Assistant, "a2", "e3"),
  ])
  inspect(stale.lane_key == latest.lane_key, content="true")
  engine.mark_dirty(stale)
  engine.mark_dirty(latest)
  guard engine.lane_state(latest.lane_key) is Some(lane) else {
    fail("expected a lane after mark_dirty")
  }
  guard lane.pending is Some(pending) else {
    fail("expected a pending request")
  }
  inspect(pending.messages.length(), content="4")
  inspect(lane.created, content="false")
  engine.drain_once(transport, timeout_ms=1000)
  guard engine.lane_state(latest.lane_key) is Some(drained) else {
    fail("expected a lane after drain_once")
  }
  inspect(drained.pending is None, content="true")
  inspect(drained.created, content="true")
  guard drained.acknowledged is Some(acked) else {
    fail("expected an acknowledged cursor")
  }
  inspect(acked.remote_count, content="4")
  inspect(transport.requests.length(), content="1")
}

///|
async test "SyncEngine: flusher_loop drains pending lanes until stop" {
  let transport = FakeNmemTransport::FakeNmemTransport([
    Reply(
      200,
      j("{\"thread\":{\"thread_id\":\"posoco-s1\",\"message_count\":2}}"),
    ),
  ])
  let engine = SyncEngine::new()
  let request = sync_request()
  engine.mark_dirty(request)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      engine.flusher_loop(transport, interval_ms=1, timeout_ms=1000)
    })
    @async.sleep(10)
    engine.stop()
  })
  inspect(engine.stopped, content="true")
  inspect(transport.requests.length(), content="1")
  guard engine.lane_state(request.lane_key) is Some(lane) else {
    fail("expected lane state after the loop")
  }
  inspect(lane.created, content="true")
  inspect(lane.pending is None, content="true")
}
