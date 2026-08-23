///|
/// Parse a fixed JSON literal; a malformed fixture aborts the test.
fn j(text : String) -> Json {
  try! @json.parse(text)
}

///|
test "is_thread_append_ack: accepts success with integral counts" {
  inspect(
    is_thread_append_ack(
      j("{\"success\":true,\"messages_added\":0,\"total_messages\":5}"),
    ),
    content="true",
  )
  // Number.isInteger parity: negative integers count as integers.
  inspect(
    is_thread_append_ack(
      j("{\"success\":true,\"messages_added\":-1,\"total_messages\":-2}"),
    ),
    content="true",
  )
  inspect(
    is_thread_append_ack(
      j("{\"success\":true,\"messages_added\":2147483647,\"total_messages\":0}"),
    ),
    content="true",
  )
}

///|
test "is_thread_append_ack: rejects non-integers, wrong types, and missing fields" {
  inspect(
    is_thread_append_ack(
      j("{\"success\":true,\"messages_added\":1.5,\"total_messages\":5}"),
    ),
    content="false",
  )
  inspect(
    is_thread_append_ack(
      j("{\"success\":true,\"messages_added\":\"3\",\"total_messages\":5}"),
    ),
    content="false",
  )
  inspect(
    is_thread_append_ack(
      j("{\"success\":true,\"messages_added\":null,\"total_messages\":5}"),
    ),
    content="false",
  )
  inspect(
    is_thread_append_ack(j("{\"success\":true,\"messages_added\":2}")),
    content="false",
  )
  inspect(
    is_thread_append_ack(j("{\"success\":true,\"total_messages\":5}")),
    content="false",
  )
  inspect(
    is_thread_append_ack(j("{\"messages_added\":1,\"total_messages\":5}")),
    content="false",
  )
  inspect(
    is_thread_append_ack(
      j("{\"success\":\"true\",\"messages_added\":1,\"total_messages\":5}"),
    ),
    content="false",
  )
  inspect(
    is_thread_append_ack(
      j("{\"success\":1,\"messages_added\":1,\"total_messages\":5}"),
    ),
    content="false",
  )
  inspect(
    is_thread_append_ack(
      j("{\"success\":false,\"messages_added\":1,\"total_messages\":5}"),
    ),
    content="false",
  )
  inspect(is_thread_append_ack(j("[1,2]")), content="false")
  inspect(is_thread_append_ack(j("\"ack\"")), content="false")
  inspect(is_thread_append_ack(j("7")), content="false")
}

///|
test "is_thread_append_ack: rejects counts beyond the 32-bit Int range" {
  // Upstream Number.isInteger would accept these; MoonBit Int is 32-bit, so
  // an unrepresentable count is conservatively read as absent.
  inspect(
    is_thread_append_ack(
      j("{\"success\":true,\"messages_added\":2147483648,\"total_messages\":5}"),
    ),
    content="false",
  )
  inspect(
    is_thread_append_ack(
      j("{\"success\":true,\"messages_added\":1,\"total_messages\":1e300}"),
    ),
    content="false",
  )
}

///|
test "is_checkpointed_append_ack: append ack plus checkpointed append_mode" {
  inspect(
    is_checkpointed_append_ack(
      j(
        "{\"success\":true,\"messages_added\":1,\"total_messages\":2,\"append_mode\":\"checkpointed\"}",
      ),
    ),
    content="true",
  )
  inspect(
    is_checkpointed_append_ack(
      j("{\"success\":true,\"messages_added\":1,\"total_messages\":2}"),
    ),
    content="false",
  )
  inspect(
    is_checkpointed_append_ack(
      j(
        "{\"success\":true,\"messages_added\":1,\"total_messages\":2,\"append_mode\":\"simple\"}",
      ),
    ),
    content="false",
  )
  inspect(
    is_checkpointed_append_ack(
      j(
        "{\"success\":true,\"messages_added\":1,\"total_messages\":2,\"append_mode\":7}",
      ),
    ),
    content="false",
  )
  // Not an append ack at all.
  inspect(
    is_checkpointed_append_ack(j("{\"append_mode\":\"checkpointed\"}")),
    content="false",
  )
}

///|
test "is_checkpoint_conflict: only the error_code field decides" {
  inspect(
    is_checkpoint_conflict(j("{\"error_code\":\"checkpoint_conflict\"}")),
    content="true",
  )
  inspect(
    is_checkpoint_conflict(j("{\"error_code\":\"other\"}")),
    content="false",
  )
  inspect(
    is_checkpoint_conflict(j("{\"error\":\"checkpoint_conflict\"}")),
    content="false",
  )
  inspect(is_checkpoint_conflict(j("{\"error_code\":123}")), content="false")
  inspect(is_checkpoint_conflict(j("{}")), content="false")
  inspect(is_checkpoint_conflict(j("\"checkpoint_conflict\"")), content="false")
}

///|
test "is_thread_already_exists: 409 status or phrase in the body" {
  inspect(
    is_thread_already_exists(409, j("{\"error\":\"unrelated\"}")),
    content="true",
  )
  // Case-insensitive phrase match in the serialized body.
  inspect(
    is_thread_already_exists(201, j("{\"error\":\"Thread Already Exists\"}")),
    content="true",
  )
  inspect(
    is_thread_already_exists(201, j("{\"error\":\"already exists in space\"}")),
    content="true",
  )
  // Nested values are covered by the serialization.
  inspect(
    is_thread_already_exists(
      201,
      j("{\"error\":{\"message\":\"thread already exists\"}}"),
    ),
    content="true",
  )
  inspect(
    is_thread_already_exists(404, j("{\"error\":\"thread not found\"}")),
    content="false",
  )
  inspect(
    is_thread_already_exists(400, j("{\"error\":\"nope\"}")),
    content="false",
  )
}

///|
test "is_thread_not_found: error_code, 404, or phrase in the body" {
  inspect(
    is_thread_not_found(500, j("{\"error_code\":\"thread_not_found\"}")),
    content="true",
  )
  inspect(
    is_thread_not_found(404, j("{\"error\":\"unrelated\"}")),
    content="true",
  )
  inspect(
    is_thread_not_found(400, j("{\"error\":\"Thread Not Found\"}")),
    content="true",
  )
  inspect(
    is_thread_not_found(400, j("{\"error_code\":\"other\"}")),
    content="false",
  )
  inspect(is_thread_not_found(500, j("{\"error_code\":42}")), content="false")
  inspect(
    is_thread_not_found(500, j("{\"error\":\"missing thread\"}")),
    content="false",
  )
}

///|
test "is_thread_create_ack: thread.thread_id must equal the expected id" {
  inspect(
    is_thread_create_ack(
      j("{\"thread\":{\"thread_id\":\"demo-s1\"}}"),
      "demo-s1",
    ),
    content="true",
  )
  inspect(
    is_thread_create_ack(
      j("{\"thread\":{\"thread_id\":\"demo-s1\"}}"),
      "demo-s2",
    ),
    content="false",
  )
  inspect(
    is_thread_create_ack(j("{\"thread\":{\"id\":\"demo-s1\"}}"), "demo-s1"),
    content="false",
  )
  inspect(
    is_thread_create_ack(j("{\"thread\":\"demo-s1\"}"), "demo-s1"),
    content="false",
  )
  inspect(
    is_thread_create_ack(j("{\"thread\":{\"thread_id\":7}}"), "demo-s1"),
    content="false",
  )
  inspect(is_thread_create_ack(j("{\"ok\":true}"), "demo-s1"), content="false")
  inspect(is_thread_create_ack(j("\"ok\""), "demo-s1"), content="false")
}

///|
test "thread_create_remote_count: message_count wins, messages length falls back" {
  debug_inspect(
    thread_create_remote_count(j("{\"thread\":{\"message_count\":3}}")),
    content="Some(3)",
  )
  debug_inspect(
    thread_create_remote_count(j("{\"thread\":{\"message_count\":0}}")),
    content="Some(0)",
  )
  // message_count wins over the messages array when both are present.
  debug_inspect(
    thread_create_remote_count(
      j("{\"thread\":{\"message_count\":2},\"messages\":[{},{},{}]}"),
    ),
    content="Some(2)",
  )
  // Negative, fractional, or out-of-range counts fall back to messages.
  debug_inspect(
    thread_create_remote_count(
      j("{\"thread\":{\"message_count\":-1},\"messages\":[{},{},{}]}"),
    ),
    content="Some(3)",
  )
  debug_inspect(
    thread_create_remote_count(
      j("{\"thread\":{\"message_count\":1.5},\"messages\":[{}]}"),
    ),
    content="Some(1)",
  )
  debug_inspect(
    thread_create_remote_count(
      j(
        "{\"thread\":{\"message_count\":3000000000},\"messages\":[{},{},{},{}]}",
      ),
    ),
    content="Some(4)",
  )
  debug_inspect(
    thread_create_remote_count(j("{\"thread\":{},\"messages\":[{},{}]}")),
    content="Some(2)",
  )
  debug_inspect(
    thread_create_remote_count(j("{\"thread\":{}}")),
    content="None",
  )
  debug_inspect(
    thread_create_remote_count(j("{\"messages\":[{}]}")),
    content="None",
  )
  debug_inspect(
    thread_create_remote_count(j("{\"thread\":\"nope\"}")),
    content="None",
  )
}
