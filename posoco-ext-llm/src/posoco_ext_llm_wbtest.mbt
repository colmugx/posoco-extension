// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

// ---------------------------------------------------------------------------
// M0-T07-B: error-transparency fixtures (offline, no network).
// ---------------------------------------------------------------------------

///|
/// Build an OpenAI Responses API output item (function_call) with given args.
fn build_function_call_json(
  id : String,
  name : String,
  args_str : String,
) -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("function_call")),
      ("call_id", Json::string(id)),
      ("name", Json::string(name)),
      ("arguments", Json::string(args_str)),
    ]),
  )
}

///|
/// T07-B: malformed tool-call arguments JSON must raise ResponseParse,
/// not silently become {}.
test "t07b_llm_malformed_tool_args_raises" {
  let bad_call = build_function_call_json("tc_1", "bad", "not-valid-json")
  let resp_json = Json::object(
    Map::from_array([
      ("output", Json::array([bad_call])),
      ("status", Json::string("completed")),
    ]),
  )
  let result = Ok(parse_openai_response(resp_json)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(_)) => ()
    _ => fail("expected ResponseParse for malformed tool arguments")
  }
}

///|
/// T07-B: valid tool-call arguments still decode correctly (no false positive).
test "t07b_llm_valid_tool_args_still_decode" {
  let ok_call = build_function_call_json("tc_1", "ok", "{}")
  let resp_json = Json::object(
    Map::from_array([
      ("output", Json::array([ok_call])),
      ("status", Json::string("completed")),
    ]),
  )
  let resp = parse_openai_response(resp_json)
  assert_eq(resp.tool_calls.length(), 1)
  assert_eq(resp.tool_calls[0].name, "ok")
}

///|
test "t07b_llm_malformed_sse_is_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator::new()
  let secret = "secret-sse-payload"
  let result = Ok(process_sse_event(secret, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("stage=json"))
      assert_false(msg.contains(secret))
    }
    _ => fail("expected ResponseParse for malformed SSE JSON")
  }
}

///|
test "t07b_llm_valid_delta_and_completed_events" {
  let acc = @posoco.StreamAccumulator::new()
  let chunks : Array[@posoco.StreamChunk] = []
  let delta =
    #|{"type":"response.output_text.delta","delta":"hello"}
  let completed =
    #|{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3}}}
  assert_false(process_sse_event(delta, acc, fn(c) { chunks.push(c) }))
  assert_true(process_sse_event(completed, acc, fn(c) { chunks.push(c) }))
  assert_eq(acc.text, "hello")
  match acc.usage {
    Some(usage) => {
      assert_true(usage.input_tokens == Some(2))
      assert_true(usage.output_tokens == Some(1))
      assert_true(usage.total_tokens == Some(3))
    }
    None => fail("expected nested completed response usage")
  }
  assert_true(chunks[chunks.length() - 1] is @posoco.StreamChunk::Finish(_))
}

///|
test "t07b_llm_incomplete_and_error_events_are_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator::new()
  let incomplete =
    #|{"type":"response.incomplete","response":{"status":"incomplete","error":{"message":"secret-incomplete"}}}
  let incomplete_result = Ok(process_sse_event(incomplete, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match incomplete_result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=response.incomplete"))
      assert_false(message.contains("secret-incomplete"))
    }
    _ => fail("response.incomplete must be a typed terminal failure")
  }
  let error_event =
    #|{"type":"error","code":"bad","message":"secret-error-body","param":null}
  let error_result = Ok(process_sse_event(error_event, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match error_result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=error"))
      assert_false(message.contains("secret-error-body"))
    }
    _ => fail("error event must be a typed terminal failure")
  }
}

///|
test "t07b_llm_completed_event_structure_and_usage_are_strict" {
  let acc = @posoco.StreamAccumulator::new()
  let missing_output =
    #|{"type":"response.completed","response":{"status":"completed"}}
  let output_result = Ok(process_sse_event(missing_output, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match output_result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=completed.output"))
    _ => fail("completed response output is required")
  }
  let missing_total =
    #|{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1}}}
  let usage_result = Ok(process_sse_event(missing_total, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match usage_result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=usage.total_tokens"))
    _ => fail("completed response usage must preserve total_tokens")
  }
}

///|
test "t07b_llm_missing_sse_field_is_loud" {
  let acc = @posoco.StreamAccumulator::new()
  let missing_delta =
    #|{"type":"response.output_text.delta"}
  let result = Ok(process_sse_event(missing_delta, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=delta"))
    _ => fail("expected ResponseParse for missing delta")
  }
}

///|
test "t07b_llm_missing_tool_identity_is_loud" {
  let acc = @posoco.StreamAccumulator::new()
  let missing_name =
    #|{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1"}}
  let result = Ok(process_sse_event(missing_name, acc, fn(_) { () })) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=tool.name"))
    _ => fail("expected ResponseParse for missing tool name")
  }
}

///|
test "t07b_llm_stream_termination_is_protocol_driven" {
  assert_true(classify_stream_termination(ExplicitTerminal) is None)
  match classify_stream_termination(CleanEof) {
    Some(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("terminal_marker=missing"))
    _ => fail("clean EOF before terminal marker must be ResponseParse")
  }
  match classify_stream_termination(TransportFailure) {
    Some(@posoco.ModelError::Transport(msg)) =>
      assert_true(msg.contains("stage=read_stream"))
    _ => fail("read failure must be Transport")
  }
}

///|
test "t07b_llm_tool_argument_error_does_not_echo_payload" {
  let secret = "secret-tool-arguments"
  let bad_call = build_function_call_json("tc_1", "bad", secret)
  let resp_json = Json::object(
    Map::from_array([
      ("output", Json::array([bad_call])),
      ("status", Json::string("completed")),
    ]),
  )
  let result = Ok(parse_openai_response(resp_json)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("payload_chars="))
      assert_false(msg.contains(secret))
    }
    _ => fail("expected redacted ResponseParse")
  }
}

///|
test "t07b_llm_stream_tool_argument_error_is_redacted" {
  let acc = @posoco.StreamAccumulator::new()
  let secret = "secret-stream-tool-arguments"
  acc.push(
    @posoco.StreamChunk::ToolCallDelta(
      index=0,
      id=Some("call_1"),
      name=Some("bad"),
      arguments_delta=Some(secret),
    ),
  )
  let result = Ok(validate_stream_tool_calls(acc)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("payload_chars="))
      assert_false(msg.contains(secret))
    }
    _ => fail("expected redacted stream argument error")
  }
}

///|
test "t07b_llm_valid_stream_tool_call_completes" {
  let acc = @posoco.StreamAccumulator::new()
  let added =
    #|{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"read"}}
  let arguments =
    #|{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{}"}
  let completed =
    #|{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"}]}}
  assert_false(process_sse_event(added, acc, fn(_) { () }))
  assert_false(process_sse_event(arguments, acc, fn(_) { () }))
  assert_true(process_sse_event(completed, acc, fn(_) { () }))
  validate_stream_tool_calls(acc)
  let response = acc.to_response()
  assert_eq(response.tool_calls.length(), 1)
  assert_eq(response.tool_calls[0].id, "call_1")
  assert_eq(response.tool_calls[0].name, "read")
}

///|
fn assert_openai_response_parse(resp : Json, stage : String) -> Unit raise {
  let result = Ok(parse_openai_response(resp)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) =>
      assert_true(message.contains("stage=" + stage))
    _ => fail("expected OpenAI ResponseParse at " + stage)
  }
}

///|
test "t07b_llm_nonstream_output_item_shape_is_strict" {
  assert_openai_response_parse(
    { "output": [7], "status": "completed" },
    "output_item",
  )
}

///|
test "t07b_llm_nonstream_message_content_is_strict" {
  let response : Json = {
    "output": [{ "type": "message", "content": "not-an-array" }],
    "status": "completed",
  }
  assert_openai_response_parse(response, "message.content")
}

///|
test "t07b_llm_nonstream_output_text_is_strict" {
  let response : Json = {
    "output": [
      { "type": "message", "content": [{ "type": "output_text", "text": 7 }] },
    ],
    "status": "completed",
  }
  assert_openai_response_parse(response, "message.output_text.text")
}

///|
test "t07b_llm_nonstream_status_is_required_and_typed" {
  assert_openai_response_parse({ "output": [] }, "status")
  assert_openai_response_parse({ "output": [], "status": 7 }, "status")
  assert_openai_response_parse(
    { "output": [], "status": "incomplete" },
    "status",
  )
  let secret = "secret-provider-error"
  let provider_error : Json = {
    "output": [],
    "status": "failed",
    "error": { "message": "secret-provider-error" },
  }
  let result = Ok(parse_openai_response(provider_error)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=error"))
      assert_false(message.contains(secret))
    }
    _ => fail("provider error response must be loud")
  }
}

///|
test "t07b_llm_nonstream_usage_is_strict" {
  let wrong_type : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": "secret", "output_tokens": 1 },
  }
  assert_openai_response_parse(wrong_type, "usage.input_tokens")
  let missing_field : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": 1 },
  }
  assert_openai_response_parse(missing_field, "usage.output_tokens")
  let missing_total : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": 1, "output_tokens": 1 },
  }
  assert_openai_response_parse(missing_total, "usage.total_tokens")
  let wrong_total : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": 1, "output_tokens": 1, "total_tokens": "secret" },
  }
  assert_openai_response_parse(wrong_total, "usage.total_tokens")
}

///|
test "t07b_llm_valid_nonstream_response_still_decodes" {
  let response : Json = {
    "output": [
      {
        "type": "message",
        "content": [{ "type": "output_text", "text": "hello" }],
      },
    ],
    "status": "completed",
    "usage": { "input_tokens": 2, "output_tokens": 1, "total_tokens": 7 },
  }
  let decoded = parse_openai_response(response)
  assert_true(decoded.finish_reason is @posoco.FinishReason::Stop)
  match decoded.message.content {
    [@posoco.Content::Text("hello")] => ()
    _ => fail("expected decoded output text")
  }
  match decoded.usage {
    Some(usage) => {
      assert_true(usage.input_tokens == Some(2))
      assert_true(usage.output_tokens == Some(1))
      assert_true(usage.total_tokens == Some(7))
    }
    None => fail("expected decoded usage")
  }
}

///|
test "t07b_llm_http_error_formatter_is_payload_free" {
  let message = format_openai_http_error(
    "http_status",
    429,
    classify_openai_error_body(19, Some(19)),
  )
  assert_eq(
    message, "OpenAI HTTP error (stage=http_status, status=429, body_chars=19, body_category=utf8)",
  )
  assert_false(message.contains("secret-response-body"))
  let invalid_utf8 = format_openai_http_error(
    "http_status",
    502,
    classify_openai_error_body(23, None),
  )
  assert_eq(
    invalid_utf8, "OpenAI HTTP error (stage=http_status, status=502, body_bytes=23, body_category=invalid_utf8)",
  )
  let read_failed = format_openai_http_error("http_status", 503, BodyReadFailed)
  assert_true(read_failed.contains("status=503"))
  assert_true(read_failed.contains("body_category=read_failed"))
  assert_true(
    classify_openai_http_status("http_status", 200, BodyBytesUtf8(0)) is None,
  )
  assert_true(
    classify_openai_http_status("http_status", 204, BodyBytesUtf8(0)) is None,
  )
  match
    classify_openai_http_status("http_status", 429, BodyBytesInvalidUtf8(7)) {
    Some(@posoco.ModelError::Transport(error)) => {
      assert_true(error.contains("status=429"))
      assert_true(error.contains("body_category=invalid_utf8"))
    }
    _ => fail("4xx status must remain a typed HTTP transport error")
  }
}
