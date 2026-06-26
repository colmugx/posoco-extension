///|
/// Blackbox tests for posoco-ext-deepseek wire encoding/decoding.
/// These test the pure encode/decode logic without any network calls.

///|
fn user_msg(text : String) -> @posoco.Message {
  {
    role: User,
    content: [@posoco.Content::Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
}

///|
fn assistant_msg(text : String) -> @posoco.Message {
  {
    role: @posoco.Role::Assistant,
    content: [@posoco.Content::Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
}

test "encode_message_basic" {
  let msg = user_msg("hello")
  let json = encode_message(msg)
  // Should have role=user, content="hello", no reasoning_content
  guard json is Object(obj) else {
    fail("expected object")
  }
  match obj.get("role") {
    Some(String(r)) => assert_eq(r, "user")
    _ => fail("expected role string")
  }
  match obj.get("content") {
    Some(String(c)) => assert_eq(c, "hello")
    _ => fail("expected content string")
  }
  // reasoning_content must NOT be present (DeepSeek optimization)
  match obj.get("reasoning_content") {
    None => ()
    _ => fail("reasoning_content should not be encoded")
  }
}

test "encode_message_assistant_no_reasoning" {
  // Even an assistant message from a reasoning model must not carry
  // reasoning_content when re-serialized (prefix cache protection).
  let msg = assistant_msg("answer")
  let json = encode_message(msg)
  guard json is Object(obj) else {
    fail("expected object")
  }
  match obj.get("role") {
    Some(String(r)) => assert_eq(r, "assistant")
    _ => fail("expected assistant role")
  }
  match obj.get("reasoning_content") {
    None => ()
    _ => fail("assistant history must not carry reasoning_content")
  }
}

test "encode_message_with_tool_calls" {
  let msg : @posoco.Message = {
    role: @posoco.Role::Assistant,
    content: [],
    tool_calls: [
      {
        id: "call_1",
        name: "read_file",
        arguments: Json::object({ "path": Json::string("/tmp/x") }),
      },
    ],
    tool_call_id: None,
    name: None,
  }
  let json = encode_message(msg)
  guard json is Object(obj) else {
    fail("expected object")
  }
  match obj.get("tool_calls") {
    Some(Array(tcs)) => {
      assert_eq(tcs.length(), 1)
      guard tcs[0] is Object(tc0) else {
        fail("expected tool_call object")
      }
      match tc0.get("id") {
        Some(String(id)) => assert_eq(id, "call_1")
        _ => fail("expected call id")
      }
      match tc0.get("function") {
        Some(Object(f)) =>
          match f.get("name") {
            Some(String(n)) => assert_eq(n, "read_file")
            _ => fail("expected function name")
          }
        _ => fail("expected function object")
      }
    }
    _ => fail("expected tool_calls array")
  }
}

test "decode_chat_response_basic" {
  // Minimal valid DeepSeek response
  let resp_json : Json = {
    "choices": [
      {
        "message": {
          "role": "assistant",
          "content": "hello world",
        },
        "finish_reason": "stop",
      },
    ],
    "usage": {
      "prompt_tokens": 10,
      "completion_tokens": 5,
      "total_tokens": 15,
    },
  }
  let resp = decode_chat_response(resp_json)
  // Verify content
  assert_eq(resp.message.content.length(), 1)
  match resp.message.content[0] {
    Text(t) => assert_eq(t, "hello world")
    _ => fail("expected Text content")
  }
  // Verify finish reason
  assert_true(resp.finish_reason is @posoco.FinishReason::Stop)
  // Verify usage
  match resp.usage {
    Some(u) => {
      match u.total_tokens {
        Some(n) => assert_eq(n, 15)
        None => fail("expected total_tokens")
      }
    }
    None => fail("expected usage")
  }
  // Verify no reasoning (basic chat has none)
  match resp.reasoning_content {
    None => ()
    _ => fail("basic chat should have no reasoning")
  }
}

test "decode_chat_response_with_reasoning" {
  // deepseek-reasoner response includes reasoning_content
  let resp_json : Json = {
    "choices": [
      {
        "message": {
          "role": "assistant",
          "content": "42",
          "reasoning_content": "let me think...",
        },
        "finish_reason": "stop",
      },
    ],
  }
  let resp = decode_chat_response(resp_json)
  match resp.reasoning_content {
    Some(r) => assert_eq(r, "let me think...")
    None => fail("expected reasoning_content")
  }
  match resp.message.content[0] {
    Text(t) => assert_eq(t, "42")
    _ => fail("expected Text content")
  }
}

test "decode_chat_response_with_tool_calls" {
  let resp_json : Json = {
    "choices": [
      {
        "message": {
          "role": "assistant",
          "content": "",
          "tool_calls": [
            {
              "id": "call_1",
              "type": "function",
              "function": {
                "name": "read_file",
                "arguments": "{\"path\":\"/tmp/x\"}",
              },
            },
          ],
        },
        "finish_reason": "tool_calls",
      },
    ],
  }
  let resp = decode_chat_response(resp_json)
  assert_eq(resp.tool_calls.length(), 1)
  let tc = resp.tool_calls[0]
  assert_eq(tc.id, "call_1")
  assert_eq(tc.name, "read_file")
  // arguments should be parsed JSON
  guard tc.arguments is Object(args) else {
    fail("expected arguments object")
  }
  match args.get("path") {
    Some(String(p)) => assert_eq(p, "/tmp/x")
    _ => fail("expected path argument")
  }
  assert_true(resp.finish_reason is @posoco.FinishReason::ToolCalls)
}

test "decode_chat_response_api_error" {
  let resp_json : Json = {
    "error": {
      "message": "Invalid API key",
      "type": "authentication_error",
    },
  }
  // Should raise ModelError::Transport
  match
    (Ok(decode_chat_response(resp_json)) catch {
      e => Err(e)
    }) {
    Err(@posoco.ModelError::Transport(msg)) =>
      assert_true(msg.contains("Invalid API key"))
    Err(_) => fail("expected Transport error")
    Ok(_) => fail("expected error")
  }
}

///|
/// SSE parser tests — process_deepseek_sse is pure (no network).

///|
test "sse_text_delta" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  let data = "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}"
  let done = process_deepseek_sse(data, acc, fn(c) { chunks.push(c) })
  assert_false(done)
  assert_eq(chunks.length(), 1)
  assert_true(chunks[0] is @posoco.StreamChunk::TextDelta(token="hello"))
  assert_eq(acc.text, "hello")
}

///|
test "sse_reasoning_delta" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  let data = "{\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}"
  let _ = process_deepseek_sse(data, acc, fn(c) { chunks.push(c) })
  assert_eq(chunks.length(), 1)
  assert_true(chunks[0] is @posoco.StreamChunk::ReasoningDelta(token="thinking"))
  assert_eq(acc.reasoning, "thinking")
}

///|
test "sse_done_marker" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  let done = process_deepseek_sse("[DONE]", acc, fn(c) { chunks.push(c) })
  assert_true(done)
  assert_true(chunks[0] is @posoco.StreamChunk::Finish(_))
}

///|
test "sse_finish_with_usage" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  let data =
    #|{"choices":[{"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
  let done = process_deepseek_sse(data, acc, fn(c) { chunks.push(c) })
  assert_true(done)
  // Should emit Usage + Finish
  assert_true(chunks.length() >= 2)
  // Verify usage captured
  let resp = acc.to_response()
  match resp.usage {
    Some(u) =>
      match u.total_tokens {
        Some(n) => assert_eq(n, 15)
        None => fail("expected total_tokens")
      }
    None => fail("expected usage")
  }
  assert_true(resp.finish_reason is @posoco.FinishReason::Stop)
}

///|
test "sse_tool_call_delta" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  // First chunk: tool call id + name
  let data1 =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":""}}]}}]}
  let _ = process_deepseek_sse(data1, acc, fn(c) { chunks.push(c) })
  // Second chunk: arguments delta
  let data2 =
    #|{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":\"/x\"}"}}]}}]}
  let _ = process_deepseek_sse(data2, acc, fn(c) { chunks.push(c) })
  // Verify accumulator assembled tool call
  let resp = acc.to_response()
  assert_eq(resp.tool_calls.length(), 1)
  assert_eq(resp.tool_calls[0].id, "call_1")
  assert_eq(resp.tool_calls[0].name, "read_file")
  guard resp.tool_calls[0].arguments is Object(args) else {
    fail("expected arguments object")
  }
  match args.get("path") {
    Some(String(p)) => assert_eq(p, "/x")
    _ => fail("expected path argument")
  }
}
