///|
fn delta_msg(
  role : NmemRole,
  content : String,
  external_id : String,
) -> NmemThreadMessage {
  {
    role,
    content,
    metadata: Map::from_array([("external_id", Json::string(external_id))]),
  }
}

///|
fn lane_config(
  api_url? : String = "http://127.0.0.1:14242",
  mcp_url? : String = "http://127.0.0.1:14242/mcp",
  api_key? : String? = None,
  space? : String? = None,
  agent_id? : String? = None,
  host_agent_id? : String? = None,
) -> NmemConfig {
  {
    api_url,
    mcp_url,
    api_key,
    space,
    agent_id,
    host_agent_id,
    source_app: "posoco",
  }
}

///|
test "select_acked_delta: without a cursor everything is new from index zero" {
  let messages = [
    delta_msg(User, "hello", "e1"),
    delta_msg(Assistant, "hi", "e2"),
  ]
  let delta = select_acked_delta(messages, None)
  inspect(delta.start, content="0")
  inspect(delta.stop, content="2")
  inspect(delta.reset, content="false")
  inspect(delta.messages.length(), content="2")
  inspect(delta.next.count, content="2")
  inspect(delta.next.remote_count, content="2")
  debug_inspect(delta.next.last_external_id, content="Some(\"e2\")")
  inspect(
    delta.next.prefix_fingerprint == prefix_fingerprint(messages, 2),
    content="true",
  )
  // A count=0 cursor behaves the same except remote_count is preserved.
  let zero_cursor : AckedCursor = {
    count: 0,
    remote_count: 7,
    last_external_id: None,
    prefix_fingerprint: prefix_fingerprint(messages, 0),
  }
  let from_zero = select_acked_delta(messages, Some(zero_cursor))
  inspect(from_zero.start, content="0")
  inspect(from_zero.reset, content="false")
  inspect(from_zero.next.remote_count, content="7")
}

///|
test "select_acked_delta: matching cursor resumes after the acknowledged prefix" {
  let cursor = select_acked_delta(
      [delta_msg(User, "hello", "e1"), delta_msg(Assistant, "hi", "e2")],
      None,
    ).next
  let grown = [
    delta_msg(User, "hello", "e1"),
    delta_msg(Assistant, "hi", "e2"),
    delta_msg(User, "and again", "e3"),
    delta_msg(Assistant, "sure", "e4"),
  ]
  let delta = select_acked_delta(grown, Some(cursor))
  inspect(delta.start, content="2")
  inspect(delta.stop, content="4")
  inspect(delta.reset, content="false")
  inspect(delta.messages.length(), content="2")
  inspect(delta.messages[0].content, content="and again")
  inspect(delta.messages[1].content, content="sure")
  inspect(delta.next.count, content="4")
  inspect(delta.next.remote_count, content="2")
  debug_inspect(delta.next.last_external_id, content="Some(\"e4\")")
}

///|
test "select_acked_delta: rewritten prefix fingerprint forces a full reset" {
  let cursor = select_acked_delta(
      [delta_msg(User, "hello", "e1"), delta_msg(Assistant, "hi", "e2")],
      None,
    ).next
  // Same external ids and count; only the acknowledged message's content
  // changed, so the divergence is caught purely by the prefix fingerprint.
  let rewritten = [
    delta_msg(User, "hello", "e1"),
    delta_msg(Assistant, "hello again", "e2"),
    delta_msg(User, "next", "e3"),
  ]
  let delta = select_acked_delta(rewritten, Some(cursor))
  inspect(delta.start, content="0")
  inspect(delta.stop, content="3")
  inspect(delta.reset, content="true")
  inspect(delta.messages.length(), content="3")
  inspect(delta.next.count, content="3")
}

///|
test "select_acked_delta: stale last external id forces a reset" {
  let messages = [
    delta_msg(User, "hello", "e1"),
    delta_msg(Assistant, "hi", "e2"),
  ]
  let good = select_acked_delta(messages, None).next
  let stale_id : AckedCursor = { ..good, last_external_id: Some("e-other"), }
  inspect(select_acked_delta(messages, Some(stale_id)).reset, content="true")
  // A count>0 cursor without last_external_id never matches: upstream
  // compares the message's "" against undefined and treats it as a mismatch.
  let missing_id : AckedCursor = { ..good, last_external_id: None, }
  inspect(select_acked_delta(messages, Some(missing_id)).reset, content="true")
}

///|
test "select_acked_delta: cursor at the transcript end yields an empty delta" {
  let messages = [
    delta_msg(User, "hello", "e1"),
    delta_msg(Assistant, "hi", "e2"),
  ]
  let cursor = select_acked_delta(messages, None).next
  let delta = select_acked_delta(messages, Some(cursor))
  inspect(delta.start, content="2")
  inspect(delta.stop, content="2")
  inspect(delta.messages.length(), content="0")
  inspect(delta.reset, content="false")
  inspect(delta.next == cursor, content="true")
}

///|
test "select_acked_delta: out-of-range cursor count resets without indexing errors" {
  let messages = [
    delta_msg(User, "hello", "e1"),
    delta_msg(Assistant, "hi", "e2"),
  ]
  // Upstream's `||` never evaluates the divergence probe when count exceeds
  // the transcript length; the probe indexes messages[start - 1].
  let beyond : AckedCursor = {
    count: 5,
    remote_count: 5,
    last_external_id: Some("e2"),
    prefix_fingerprint: "0",
  }
  let past = select_acked_delta(messages, Some(beyond))
  inspect(past.start, content="0")
  inspect(past.reset, content="true")
  inspect(past.messages.length(), content="2")
  let negative : AckedCursor = { ..beyond, count: -1, }
  let before = select_acked_delta(messages, Some(negative))
  inspect(before.start, content="0")
  inspect(before.reset, content="true")
  inspect(before.messages.length(), content="2")
}

///|
test "prefix_fingerprint: frames each message as utf8-byte-length:text" {
  // "héllo" makes the utf8 byte length (one byte more than UTF-16 units)
  // observable in the frame prefix.
  let a = delta_msg(User, "héllo", "e1")
  let b = delta_msg(Assistant, "done", "e2")
  let fa = message_fingerprint(a)
  let fb = message_fingerprint(b)
  let stream = "\{@utf8.encode(fa).length()}:\{fa}\{@utf8.encode(fb).length()}:\{fb}"
  inspect(
    prefix_fingerprint([a, b], 2) == sha256_hex(@utf8.encode(stream)),
    content="true",
  )
}

///|
test "prefix_fingerprint: empty prefix and out-of-range bounds" {
  // sha256 of the empty string; upstream hashes the same empty stream.
  inspect(
    prefix_fingerprint([], 0) ==
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    content="true",
  )
  let messages = [delta_msg(User, "a", "e1")]
  inspect(
    prefix_fingerprint(messages, -1) == prefix_fingerprint(messages, 0),
    content="true",
  )
  inspect(
    prefix_fingerprint(messages, 5) == prefix_fingerprint(messages, 1),
    content="true",
  )
}

///|
test "select_acked_delta: same-count splits with different message boundaries mismatch" {
  // Identical external ids and count; only the fingerprint texts differ. The
  // "{length}:{text}" framing is what keeps a boundary shift from aliasing
  // the hash stream.
  let split_a = [delta_msg(User, "a", "e1"), delta_msg(Assistant, "bc", "e2")]
  let split_b = [delta_msg(User, "ab", "e1"), delta_msg(Assistant, "c", "e2")]
  let cursor = select_acked_delta(split_a, None).next
  inspect(select_acked_delta(split_a, Some(cursor)).reset, content="false")
  inspect(select_acked_delta(split_b, Some(cursor)).reset, content="true")
}

///|
test "sync_lane_key: destination hash over NUL-joined components plus thread id" {
  let destination = @crypto.bytes_to_hex_string(
    @crypto.sha256(@utf8.encode("http://127.0.0.1:14242\u{0}\u{0}\u{0}\u{0}")),
  )
  inspect(
    sync_lane_key("demo-s1", lane_config()) == "\{destination}\u{0}demo-s1",
    content="true",
  )
}

///|
test "sync_lane_key: deterministic and sensitive to every destination component" {
  let base = lane_config()
  let base_key = sync_lane_key("demo-s1", base)
  inspect(sync_lane_key("demo-s1", base) == base_key, content="true")
  inspect(
    sync_lane_key("demo-s1", lane_config(api_url="http://other:1")) != base_key,
    content="true",
  )
  inspect(
    sync_lane_key("demo-s1", lane_config(api_key=Some("k"))) != base_key,
    content="true",
  )
  inspect(
    sync_lane_key("demo-s1", lane_config(space=Some("s"))) != base_key,
    content="true",
  )
  inspect(
    sync_lane_key("demo-s1", lane_config(agent_id=Some("a"))) != base_key,
    content="true",
  )
  inspect(
    sync_lane_key("demo-s1", lane_config(host_agent_id=Some("h"))) != base_key,
    content="true",
  )
  inspect(sync_lane_key("demo-s2", base) != base_key, content="true")
  // source_app is not a lane component (upstream hashes five fields only).
  inspect(
    sync_lane_key("demo-s1", { ..lane_config(), source_app: "demo", }) ==
    base_key,
    content="true",
  )
}

///|
test "sync_lane_key: absent and blank optional components hash the same" {
  let blank = lane_config(
    api_key=Some(""),
    space=Some(""),
    agent_id=Some(""),
    host_agent_id=Some(""),
  )
  inspect(
    sync_lane_key("demo-s1", blank) == sync_lane_key("demo-s1", lane_config()),
    content="true",
  )
}
