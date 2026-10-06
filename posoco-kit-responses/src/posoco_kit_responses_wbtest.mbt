// Regression suite for the shared OpenAI Responses wire parser. The
// delegating adapters (openai, kimi) pin only their provider-prefix wiring;
// all parser behavior lives here.

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
  let result = Ok(parse_responses_response(provider="OpenAI", resp_json)) catch {
    e => Err(e)
  }
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
  let resp = parse_responses_response(provider="OpenAI", resp_json)
  let tcs = resp.tool_calls()
  assert_eq(tcs.length(), 1)
  assert_eq(tcs[0].name.to_string(), "ok")
}

///|
test "t07b_llm_malformed_sse_is_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator()
  let secret = "secret-sse-payload"
  let result = Ok(
    process_responses_sse(provider="OpenAI", secret, acc, fn(_) { () }),
  ) catch {
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
  let acc = @posoco.StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let delta =
    #|{"type":"response.output_text.delta","delta":"hello"}
  let completed =
    #|{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3}}}
  assert_false(
    process_responses_sse(provider="OpenAI", delta, acc, fn(c) {
      chunks.push(c)
    }),
  )
  assert_true(
    process_responses_sse(provider="OpenAI", completed, acc, fn(c) {
      chunks.push(c)
    }),
  )
  assert_eq(acc.text(), "hello")
  // The accumulator token fields are private; read them back through the
  // completion assembled from the accumulated chunks.
  match acc.to_completion().usage {
    Some(u) => {
      assert_true(u.input_tokens == Some(2))
      assert_true(u.output_tokens == Some(1))
      assert_true(u.total_tokens == Some(3))
    }
    None => fail("expected accumulated usage")
  }
  assert_true(chunks[chunks.length() - 1] is @posoco.StreamChunk::Finish(_))
}

///|
test "t07b_llm_incomplete_and_error_events_are_loud_and_redacted" {
  let acc = @posoco.StreamAccumulator()
  let incomplete =
    #|{"type":"response.incomplete","response":{"status":"incomplete","error":{"message":"secret-incomplete"}}}
  let incomplete_result = Ok(
    process_responses_sse(provider="OpenAI", incomplete, acc, fn(_) { () }),
  ) catch {
    e => Err(e)
  }
  match incomplete_result {
    Err(@posoco.ModelError::Transport(message)) => {
      assert_true(message.contains("stage=response.incomplete"))
      assert_false(message.contains("secret-incomplete"))
    }
    _ => fail("response.incomplete must be a typed terminal failure")
  }
  let error_event =
    #|{"type":"error","code":"bad","message":"secret-error-body","param":null}
  let error_result = Ok(
    process_responses_sse(provider="OpenAI", error_event, acc, fn(_) { () }),
  ) catch {
    e => Err(e)
  }
  match error_result {
    Err(@posoco.ModelError::Transport(message)) => {
      assert_true(message.contains("stage=error"))
      assert_false(message.contains("secret-error-body"))
    }
    _ => fail("error event must be a typed terminal failure")
  }
}

///|
/// Missing/null output on completed is tolerated as empty (Stop); missing
/// usage token fields map to None (chat-completions tolerance alignment).
test "t07b_llm_completed_event_tolerates_missing_output_and_usage_fields" {
  let acc = @posoco.StreamAccumulator()
  let chunks : Array[@posoco.StreamChunk] = []
  let missing_output =
    #|{"type":"response.completed","response":{"status":"completed"}}
  assert_true(
    process_responses_sse(provider="OpenAI", missing_output, acc, fn(c) {
      chunks.push(c)
    }),
  )
  match chunks[chunks.length() - 1] {
    // Wire spelling: the accumulator parses "stop" back into FinishReason::Stop.
    @posoco.StreamChunk::Finish(reason~) => assert_eq(reason, "stop")
    _ => fail("expected a Finish chunk for completed without output")
  }
  let missing_total =
    #|{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":1,"output_tokens":1}}}
  assert_true(
    process_responses_sse(provider="OpenAI", missing_total, acc, fn(c) {
      chunks.push(c)
    }),
  )
  // Missing total_tokens maps to None in Usage, surfaced as 0 in the chunk.
  match acc.to_completion().usage {
    Some(u) => {
      assert_true(u.input_tokens == Some(1))
      assert_true(u.total_tokens == Some(0))
    }
    None => fail("expected accumulated usage")
  }
}

///|
test "t07b_llm_missing_sse_field_is_loud" {
  let acc = @posoco.StreamAccumulator()
  let missing_delta =
    #|{"type":"response.output_text.delta"}
  let result = Ok(
    process_responses_sse(provider="OpenAI", missing_delta, acc, fn(_) { () }),
  ) catch {
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
  let acc = @posoco.StreamAccumulator()
  let missing_name =
    #|{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1"}}
  let result = Ok(
    process_responses_sse(provider="OpenAI", missing_name, acc, fn(_) { () }),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("stage=tool.name"))
    _ => fail("expected ResponseParse for missing tool name")
  }
}

///|
/// Explicit-null tolerances aligned with the chat-completions shared parser:
/// null delta events are skipped, null call_id falls back to the item id, a
/// bare {"error": ...} data line is a Transport failure, and null output /
/// message content decode as empty.
test "t07b_llm_explicit_null_fields_are_tolerated" {
  let acc = @posoco.StreamAccumulator()
  let null_delta =
    #|{"type":"response.output_text.delta","delta":null}
  assert_false(
    process_responses_sse(provider="OpenAI", null_delta, acc, fn(_) { () }),
  )
  assert_eq(acc.text(), "")
  let null_call_id =
    #|{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":null,"id":"fc_1","name":"read"}}
  let chunks : Array[@posoco.StreamChunk] = []
  assert_false(
    process_responses_sse(provider="OpenAI", null_call_id, acc, fn(c) {
      chunks.push(c)
    }),
  )
  match chunks[0] {
    @posoco.StreamChunk::ToolCallDelta(index~, id~, name~, arguments_delta~) => {
      assert_eq(index, 0)
      assert_eq(id, Some("fc_1"))
      assert_eq(name, Some("read"))
      assert_true(arguments_delta is None)
    }
    _ => fail("null call_id must fall back to the item id")
  }
  let bare_error =
    #|{"error":{"message":"secret-stream-error","type":"server_error"}}
  let error_result = Ok(
    process_responses_sse(provider="OpenAI", bare_error, acc, fn(_) { () }),
  ) catch {
    e => Err(e)
  }
  match error_result {
    Err(@posoco.ModelError::Transport(message)) => {
      assert_true(message.contains("stage=error"))
      assert_false(message.contains("secret-stream-error"))
    }
    _ => fail("a bare error data line must be a Transport failure")
  }
  let null_output : Json = { "output": null, "status": "completed" }
  assert_true(
    parse_responses_response(provider="OpenAI", null_output).finish_reason()
    is @posoco.FinishReason::Stop,
  )
  let null_content : Json = {
    "output": [{ "type": "message", "content": null }],
    "status": "completed",
  }
  assert_eq(
    parse_responses_response(provider="OpenAI", null_content).message.content.length(),
    0,
  )
}

///|
test "t07b_llm_stream_termination_is_protocol_driven" {
  assert_true(
    classify_stream_termination(provider="OpenAI", ExplicitTerminal) is None,
  )
  match classify_stream_termination(provider="OpenAI", CleanEof) {
    Some(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("terminal_marker=missing"))
    _ => fail("clean EOF before terminal marker must be ResponseParse")
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
  let result = Ok(parse_responses_response(provider="OpenAI", resp_json)) catch {
    e => Err(e)
  }
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
  let acc = @posoco.StreamAccumulator()
  let secret = "secret-stream-tool-arguments"
  acc.push(
    @posoco.StreamChunk::ToolCallDelta(
      index=0,
      id=Some("call_1"),
      name=Some("bad"),
      arguments_delta=Some(secret),
    ),
  )
  let result = Ok(validate_stream_tool_calls(provider="OpenAI", acc)) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("OpenAI SSE parse failure (stage=tool_calls)"))
      assert_true(msg.contains("malformed tool-call arguments JSON"))
      assert_false(msg.contains(secret))
    }
    _ => fail("expected redacted stream argument error")
  }
}

///|
test "t07b_llm_valid_stream_tool_call_completes" {
  let acc = @posoco.StreamAccumulator()
  let added =
    #|{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"read"}}
  let arguments =
    #|{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{}"}
  let completed =
    #|{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"}]}}
  assert_false(
    process_responses_sse(provider="OpenAI", added, acc, fn(_) { () }),
  )
  assert_false(
    process_responses_sse(provider="OpenAI", arguments, acc, fn(_) { () }),
  )
  assert_true(
    process_responses_sse(provider="OpenAI", completed, acc, fn(_) { () }),
  )
  validate_stream_tool_calls(provider="OpenAI", acc)
  let completion = acc.to_completion()
  let tcs = completion.tool_calls()
  assert_eq(tcs.length(), 1)
  assert_eq(tcs[0].call_id.to_string(), "call_1")
  assert_eq(tcs[0].name.to_string(), "read")
}

///|
fn assert_openai_response_parse(resp : Json, stage : String) -> Unit raise {
  let result = Ok(parse_responses_response(provider="OpenAI", resp)) catch {
    e => Err(e)
  }
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
  let result = Ok(parse_responses_response(provider="OpenAI", provider_error)) catch {
    e => Err(e)
  }
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
  let wrong_total : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": 1, "output_tokens": 1, "total_tokens": "secret" },
  }
  assert_openai_response_parse(wrong_total, "usage.total_tokens")
  // Missing usage token fields map to None instead of failing.
  let missing_fields : Json = {
    "output": [],
    "status": "completed",
    "usage": { "input_tokens": 1 },
  }
  let decoded = parse_responses_response(provider="OpenAI", missing_fields)
  match decoded.usage {
    Some(usage) => {
      assert_true(usage.input_tokens == Some(1))
      assert_true(usage.output_tokens is None)
      assert_true(usage.total_tokens is None)
    }
    None => fail("expected decoded usage")
  }
  // "usage": null is treated as absent.
  let null_usage : Json = { "output": [], "status": "completed", "usage": null }
  assert_true(
    parse_responses_response(provider="OpenAI", null_usage).usage is None,
  )
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
  let decoded = parse_responses_response(provider="OpenAI", response)
  assert_true(decoded.finish_reason() is @posoco.FinishReason::Stop)
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
test "responses usage carries cached input tokens" {
  let resp : Json = {
    "usage": {
      "input_tokens": 1200,
      "output_tokens": 50,
      "total_tokens": 1250,
      "input_tokens_details": { "cached_tokens": 1000 },
    },
  }
  match extract_usage(provider="OpenAI", resp) {
    Some(u) => {
      assert_eq(u.input_tokens, Some(1200))
      assert_eq(u.cached_input_tokens, Some(1000))
    }
    None => fail("expected usage")
  }
  // Absent details read as None; a wrong type stays loud.
  let no_details : Json = {
    "usage": { "input_tokens": 10, "output_tokens": 5, "total_tokens": 15 },
  }
  match extract_usage(provider="OpenAI", no_details) {
    Some(u) => assert_true(u.cached_input_tokens is None)
    None => fail("expected usage")
  }
  let bad_details : Json = {
    "usage": {
      "input_tokens": 10,
      "output_tokens": 5,
      "total_tokens": 15,
      "input_tokens_details": { "cached_tokens": "many" },
    },
  }
  let outcome : Result[@posoco.Usage?, Error] = Ok(
    extract_usage(provider="OpenAI", bad_details),
  ) catch {
    error => Err(error)
  }
  assert_true(outcome is Err(_))
}

///|
/// Manual state management (migrate-to-responses guide): an assistant message
/// with tool calls expands into a message item PLUS one function_call item
/// per call — dropping function_call items is a named common migration error.
test "openai_input_assistant_tool_calls_emit_function_call_items" {
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("let me check")],
    tool_calls=[
      {
        call_id: @posoco.CallId::unchecked("call_1"),
        name: @posoco.ToolName::unchecked("read"),
        arguments: Json::object({ "path": Json::string("/tmp/x") }),
      },
    ],
    reasoning=None,
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let items = message_to_responses_items(msg)
  assert_eq(items.length(), 2)
  guard items[0] is Object(m0) else { fail("expected message item") }
  match m0.get("role") {
    Some(String("assistant")) => ()
    _ => fail("expected assistant message item")
  }
  guard m0.get("content") is Some(Json::Array([Json::Object(part)])) else {
    fail("expected single assistant content part")
  }
  assert_eq(part.get("type"), Some(Json::string("output_text")))
  guard items[1] is Object(fc) else { fail("expected function_call item") }
  match fc.get("type") {
    Some(String("function_call")) => ()
    _ => fail("expected function_call type")
  }
  match fc.get("call_id") {
    Some(String(id)) => assert_eq(id, "call_1")
    _ => fail("expected call_id")
  }
  match fc.get("name") {
    Some(String(n)) => assert_eq(n, "read")
    _ => fail("expected name")
  }
  match fc.get("arguments") {
    Some(String(a)) => assert_true(a.contains("/tmp/x"))
    _ => fail("expected arguments string")
  }
}

///|
/// Reasoning items replay verbatim ahead of the assistant message item
/// (official reasoning guide: pass back all reasoning items untouched).
test "openai_input_replays_reasoning_items_verbatim" {
  let raw_item = Json::object(
    Map::from_array([
      ("id", Json::string("rs_123")),
      ("type", Json::string("reasoning")),
      ("summary", Json::array([])),
      ("encrypted_content", Json::string("enc_payload")),
    ]),
  )
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{
      content: "",
      raw: Some(Json::array([raw_item])),
    }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let items = message_to_responses_items(msg)
  assert_eq(items.length(), 2)
  assert_true(items[0] == raw_item)
  guard items[1] is Object(m1) else { fail("expected message item") }
  match m1.get("role") {
    Some(String("assistant")) => ()
    _ => fail("expected assistant message item after reasoning")
  }
}

///|
/// Assistant-role text must encode as `output_text`; the Responses API
/// rejects `input_text` on assistant messages with a 400
/// invalid_value (this broke history replay and post-compact windows).
test "assistant_text_encodes_as_output_text_parts" {
  let msg : @posoco.Message = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
  let items = message_to_responses_items(msg)
  assert_eq(items.length(), 1)
  guard items[0] is Object(m) else { fail("expected message item") }
  match m.get("role") {
    Some(String("assistant")) => ()
    _ => fail("expected assistant role")
  }
  guard m.get("content") is Some(Json::Array([Json::Object(part)])) else {
    fail("expected single content part")
  }
  assert_eq(part.get("type"), Some(Json::string("output_text")))
  assert_eq(part.get("text"), Some(Json::string("answer")))
}

///|
/// Input-side roles keep `input_text`: only the assistant message is
/// restricted to `output_text`.
test "user_and_system_keep_input_text_parts" {
  let user : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("question"),
  ])
  let user_items = message_to_responses_items(user)
  guard user_items[0] is Object(um) else { fail("expected user item") }
  guard um.get("content") is Some(Json::Array([Json::Object(upart)])) else {
    fail("expected single user content part")
  }
  assert_eq(upart.get("type"), Some(Json::string("input_text")))
  let system : @posoco.Message = @posoco.Message::SystemMessage(content=[
    @posoco.Content::Text("policy"),
  ])
  let system_items = message_to_responses_items(system)
  guard system_items[0] is Object(sm) else { fail("expected system item") }
  guard sm.get("content") is Some(Json::Array([Json::Object(spart)])) else {
    fail("expected single system content part")
  }
  assert_eq(spart.get("type"), Some(Json::string("input_text")))
}

///|
/// Responses with a reasoning item surface it on the Completion: summary text
/// as user-visible content, the raw item preserved for replay.
test "openai_parse_captures_reasoning_items" {
  let reasoning_item = Json::object(
    Map::from_array([
      ("id", Json::string("rs_9")),
      ("type", Json::string("reasoning")),
      (
        "summary",
        Json::array([
          Json::object(
            Map::from_array([
              ("type", Json::string("summary_text")),
              ("text", Json::string("thought hard")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  let message_item = Json::object(
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
  let resp_json = Json::object(
    Map::from_array([
      ("output", Json::array([reasoning_item, message_item])),
      ("status", Json::string("completed")),
    ]),
  )
  let resp = parse_responses_response(provider="OpenAI", resp_json)
  match resp.message.reasoning {
    Some(r) => {
      assert_eq(r.content, "thought hard")
      assert_true(r.raw == Some(Json::array([reasoning_item])))
    }
    None => fail("reasoning item must be captured")
  }
}

///|
/// Streaming: reasoning items on the terminal response.completed event are
/// captured into the sink (the adapters attach them to the completion).
test "openai_stream_captures_reasoning_items_from_completed" {
  let acc = @posoco.StreamAccumulator()
  let sink = SseStreamState::SseStreamState()
  let completed =
    #|{"type":"response.completed","response":{"status":"completed","output":[{"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"s"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}]}}
  assert_true(
    process_responses_sse(
      provider="OpenAI",
      completed,
      acc,
      fn(_) { () },
      state=sink,
    ),
  )
  assert_eq(sink.summary, "s")
  assert_eq(sink.items.length(), 1)
}

///|
test "openai extract_reasoning_items falls back to content text" {
  let item_without_summary : Json = {
    "type": "reasoning",
    "id": "rs_3",
    "summary": [],
    "content": [{ "type": "reasoning_text", "text": "visible raw thought" }],
  }
  let (raw, text) = extract_reasoning_items(
    provider="OpenAI",
    Json::array([item_without_summary]),
  )
  assert_eq(text, "visible raw thought")
  assert_eq(raw.length(), 1)
  // Summary text still wins when both are present.
  let item_with_summary : Json = {
    "type": "reasoning",
    "id": "rs_4",
    "summary": [{ "type": "summary_text", "text": "summary wins" }],
    "content": [{ "type": "reasoning_text", "text": "raw loses" }],
  }
  let (_, mixed) = extract_reasoning_items(
    provider="OpenAI",
    Json::array([item_with_summary]),
  )
  assert_eq(mixed, "summary wins")
}

///|
test "openai sse reasoning summary deltas stream as reasoning" {
  let events : Array[String] = [
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"content\":[]}}",
    "{\"type\":\"response.reasoning_summary_part.added\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0}",
    "{\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"delta\":\"Think\"}",
    "{\"type\":\"response.reasoning_summary_text.delta\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0,\"delta\":\"ing\"}",
    "{\"type\":\"response.reasoning_summary_part.done\",\"item_id\":\"rs_1\",\"output_index\":0,\"summary_index\":0}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"Thinking\"}],\"content\":[],\"encrypted_content\":\"enc\"}}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":100,\"output_tokens\":5,\"total_tokens\":105,\"input_tokens_details\":{\"cached_tokens\":40,\"cache_write_tokens\":0},\"output_tokens_details\":{\"reasoning_tokens\":2}}}}",
  ]
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let st = SseStreamState::SseStreamState()
  let chunks : Array[@posoco.StreamChunk] = []
  let mut terminal = false
  for ev in events {
    if process_responses_sse(
        provider="OpenAI",
        ev,
        acc,
        fn(c) { chunks.push(c) },
        state=st,
      ) {
      terminal = true
    }
  }
  assert_true(terminal)
  // Summary deltas (plus the part separator) surface as reasoning chunks.
  let reasoning_tokens = chunks.filter(fn(c) { c is ReasoningDelta(..) })
  assert_eq(reasoning_tokens.length(), 3)
  assert_true(reasoning_tokens[0] is ReasoningDelta(token="Think"))
  assert_true(reasoning_tokens[1] is ReasoningDelta(token="ing"))
  assert_true(reasoning_tokens[2] is ReasoningDelta(token="\n\n"))
  let completion = acc.to_completion()
  // The summary text accumulated as reasoning content on the completion.
  match completion.message.reasoning {
    Some(reasoning) => assert_eq(reasoning.content, "Thinking\n\n")
    None => fail("reasoning must ride the completion")
  }
  // The done event captured the reasoning item exactly once for replay.
  assert_eq(st.items.length(), 1)
  // The completed usage reports the cached input share.
  match completion.usage {
    Some({ cached_input_tokens: Some(cached), input_tokens: Some(input), .. }) => {
      assert_eq(cached, 40)
      assert_eq(input, 100)
    }
    _ => fail("usage must ride the completion")
  }
}

///|
test "openai sse raw reasoning text streams and item content backfills" {
  let events : Array[String] = [
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"rs_2\",\"type\":\"reasoning\",\"summary\":[],\"content\":[]}}",
    "{\"type\":\"response.reasoning_text.delta\",\"item_id\":\"rs_2\",\"output_index\":0,\"content_index\":0,\"delta\":\"step one\"}",
    "{\"type\":\"response.reasoning_text.done\",\"item_id\":\"rs_2\",\"output_index\":0,\"content_index\":0,\"text\":\"step one\"}",
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_2\",\"type\":\"reasoning\",\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"step one\"}],\"encrypted_content\":\"enc2\"}}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"status\":\"completed\",\"output\":[]}}",
  ]
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let st = SseStreamState::SseStreamState()
  let mut terminal = false
  for ev in events {
    if process_responses_sse(provider="OpenAI", ev, acc, fn(_) { () }, state=st) {
      terminal = true
    }
  }
  assert_true(terminal)
  // Raw reasoning text accumulates as the completion's reasoning content.
  let completion = acc.to_completion()
  match completion.message.reasoning {
    Some(reasoning) => assert_eq(reasoning.content, "step one")
    None => fail("reasoning must ride the completion")
  }
  // The done event captured the item for verbatim replay.
  assert_eq(st.items.length(), 1)
}

///|
/// Real-wire corpus regression: two SSE streams captured verbatim from the
/// Codex backend (chatgpt.com/backend-api/codex/responses), one low-effort
/// with a single function_call at output_index 0, one effort=max where a
/// reasoning item occupies output_index 0 and the function_call sits at
/// output_index 1. Guards the wire-format contract end to end: compact
/// tool-slot remapping, done-event identity/reasoning capture, terminal
/// output[]=[] tolerance, and the wire-spelled finish reason.
/// Request-specific identifiers, timestamps, obfuscation tokens, and opaque
/// encrypted payloads in this production-shaped fixture are synthetic.
test "openai codex-shaped sse corpus replays to tool calls" {
  let low : Array[String] = [
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_fixture000000000000000000000000000000000000000001\",\"object\":\"response\",\"created_at\":1700000000,\"status\":\"in_progress\",\"background\":false,\"completed_at\":null,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"00000000-0000-4000-8000-000000000001\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"low\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-fixture-00000000000000000001\",\"service_tier\":\"auto\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":null,\"user\":null,\"metadata\":{}},\"sequence_number\":0}",
    "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_fixture000000000000000000000000000000000000000001\",\"object\":\"response\",\"created_at\":1700000000,\"status\":\"in_progress\",\"background\":false,\"completed_at\":null,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"00000000-0000-4000-8000-000000000001\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"low\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-fixture-00000000000000000001\",\"service_tier\":\"auto\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":null,\"user\":null,\"metadata\":{}},\"sequence_number\":1}",
    "{\"type\":\"response.output_item.added\",\"item\":{\"id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"type\":\"function_call\",\"status\":\"in_progress\",\"arguments\":\"\",\"call_id\":\"call_fixture000000000000000001\",\"name\":\"read\"},\"output_index\":0,\"sequence_number\":2}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"obfuscation\":\"fixtureObf01\",\"output_index\":0,\"sequence_number\":3}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"path\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"obfuscation\":\"fixtureObf02\",\"output_index\":0,\"sequence_number\":4}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\":\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"obfuscation\":\"fixtureObf03\",\"output_index\":0,\"sequence_number\":5}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\"/\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"obfuscation\":\"fixtureObf04\",\"output_index\":0,\"sequence_number\":6}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"tmp\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"obfuscation\":\"fixtureObf05\",\"output_index\":0,\"sequence_number\":7}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"/\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"obfuscation\":\"fixtureObf06\",\"output_index\":0,\"sequence_number\":8}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"notes\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"obfuscation\":\"fixtureObf07\",\"output_index\":0,\"sequence_number\":9}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\".txt\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"obfuscation\":\"fixtureObf08\",\"output_index\":0,\"sequence_number\":10}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\"}\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"obfuscation\":\"fixtureObf09\",\"output_index\":0,\"sequence_number\":11}",
    "{\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/notes.txt\\\"}\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"output_index\":0,\"sequence_number\":12}",
    "{\"type\":\"response.output_item.done\",\"item\":{\"id\":\"fc_fixture0000000000000000000000000000000000000000001\",\"type\":\"function_call\",\"status\":\"completed\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/notes.txt\\\"}\",\"call_id\":\"call_fixture000000000000000001\",\"name\":\"read\"},\"output_index\":0,\"sequence_number\":13}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fixture000000000000000000000000000000000000000001\",\"object\":\"response\",\"created_at\":1700000000,\"status\":\"completed\",\"background\":false,\"completed_at\":1700000001,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"00000000-0000-4000-8000-000000000001\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"low\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-fixture-00000000000000000001\",\"service_tier\":\"default\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":{\"attribution\":{\"items\":{\"msg_fixture000000000000000000000000000000000000000001\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"content\":[{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":30,\"output_tokens\":0}],\"input_tokens\":30,\"output_tokens\":0},\"fc_fixture0000000000000000000000000000000000000000001\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":2,\"output_tokens\":21}},\"request_fields\":{\"tools\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":39,\"output_tokens\":0}}},\"input_tokens\":71,\"input_tokens_details\":{\"cache_write_tokens\":0,\"cached_tokens\":0},\"output_tokens\":21,\"output_tokens_details\":{\"reasoning_tokens\":0},\"total_tokens\":92},\"user\":null,\"metadata\":{}},\"sequence_number\":14}",
  ]
  let max_effort : Array[String] = [
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_fixture000000000000000000000000000000000000000002\",\"object\":\"response\",\"created_at\":1700000100,\"status\":\"in_progress\",\"background\":false,\"completed_at\":null,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"00000000-0000-4000-8000-000000000002\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"max\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-fixture-00000000000000000001\",\"service_tier\":\"auto\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":null,\"user\":null,\"metadata\":{}},\"sequence_number\":0}",
    "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_fixture000000000000000000000000000000000000000002\",\"object\":\"response\",\"created_at\":1700000100,\"status\":\"in_progress\",\"background\":false,\"completed_at\":null,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"00000000-0000-4000-8000-000000000002\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"max\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-fixture-00000000000000000001\",\"service_tier\":\"auto\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":null,\"user\":null,\"metadata\":{}},\"sequence_number\":1}",
    "{\"type\":\"response.output_item.added\",\"item\":{\"id\":\"rs_fixture0000000000000000000000000000000000000000001\",\"type\":\"reasoning\",\"content\":[],\"encrypted_content\":\"encrypted-fixture-payload-1\",\"summary\":[]},\"output_index\":0,\"sequence_number\":2}",
    "{\"type\":\"response.output_item.done\",\"item\":{\"id\":\"rs_fixture0000000000000000000000000000000000000000001\",\"type\":\"reasoning\",\"content\":[],\"encrypted_content\":\"encrypted-fixture-payload-2\",\"summary\":[]},\"output_index\":0,\"sequence_number\":3}",
    "{\"type\":\"response.output_item.added\",\"item\":{\"id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"type\":\"function_call\",\"status\":\"in_progress\",\"arguments\":\"\",\"call_id\":\"call_fixture000000000000000002\",\"name\":\"read\"},\"output_index\":1,\"sequence_number\":4}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"obfuscation\":\"fixtureObf10\",\"output_index\":1,\"sequence_number\":5}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"path\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"obfuscation\":\"fixtureObf11\",\"output_index\":1,\"sequence_number\":6}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\":\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"obfuscation\":\"fixtureObf12\",\"output_index\":1,\"sequence_number\":7}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\"/\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"obfuscation\":\"fixtureObf13\",\"output_index\":1,\"sequence_number\":8}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"tmp\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"obfuscation\":\"fixtureObf14\",\"output_index\":1,\"sequence_number\":9}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"/\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"obfuscation\":\"fixtureObf15\",\"output_index\":1,\"sequence_number\":10}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"notes\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"obfuscation\":\"fixtureObf16\",\"output_index\":1,\"sequence_number\":11}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\".txt\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"obfuscation\":\"fixtureObf17\",\"output_index\":1,\"sequence_number\":12}",
    "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\"}\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"obfuscation\":\"fixtureObf18\",\"output_index\":1,\"sequence_number\":13}",
    "{\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/notes.txt\\\"}\",\"item_id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"output_index\":1,\"sequence_number\":14}",
    "{\"type\":\"response.output_item.done\",\"item\":{\"id\":\"fc_fixture0000000000000000000000000000000000000000002\",\"type\":\"function_call\",\"status\":\"completed\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/notes.txt\\\"}\",\"call_id\":\"call_fixture000000000000000002\",\"name\":\"read\"},\"output_index\":1,\"sequence_number\":15}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fixture000000000000000000000000000000000000000002\",\"object\":\"response\",\"created_at\":1700000100,\"status\":\"completed\",\"background\":false,\"completed_at\":1700000101,\"error\":null,\"frequency_penalty\":0.0,\"incomplete_details\":null,\"instructions\":null,\"max_output_tokens\":null,\"max_tool_calls\":null,\"model\":\"gpt-5.6-luna\",\"moderation\":null,\"output\":[],\"parallel_tool_calls\":true,\"presence_penalty\":0.0,\"previous_response_id\":null,\"prompt_cache_key\":\"00000000-0000-4000-8000-000000000002\",\"prompt_cache_retention\":\"24h\",\"reasoning\":{\"context\":\"all_turns\",\"effort\":\"max\",\"mode\":\"standard\",\"summary\":\"detailed\"},\"safety_identifier\":\"user-fixture-00000000000000000001\",\"service_tier\":\"default\",\"store\":false,\"temperature\":1.0,\"text\":{\"format\":{\"type\":\"text\"},\"verbosity\":\"medium\"},\"tool_choice\":\"auto\",\"tool_usage\":{\"image_gen\":{\"input_tokens\":0,\"input_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"output_tokens\":0,\"output_tokens_details\":{\"image_tokens\":0,\"text_tokens\":0},\"total_tokens\":0},\"web_search\":{\"num_requests\":0}},\"tools\":[{\"type\":\"function\",\"description\":\"Read a file from disk\",\"name\":\"read\",\"output_schema\":null,\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"absolute path\"}},\"required\":[\"path\"],\"additionalProperties\":false},\"strict\":true}],\"top_logprobs\":0,\"top_p\":0.98,\"truncation\":\"disabled\",\"usage\":{\"attribution\":{\"items\":{\"msg_fixture000000000000000000000000000000000000000002\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"content\":[{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":30,\"output_tokens\":0}],\"input_tokens\":30,\"output_tokens\":0},\"rs_fixture0000000000000000000000000000000000000000001\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":2,\"output_tokens\":11},\"fc_fixture0000000000000000000000000000000000000000002\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":0,\"output_tokens\":23}},\"request_fields\":{\"tools\":{\"cache_write_tokens\":0,\"cached_tokens\":0,\"input_tokens\":39,\"output_tokens\":0}}},\"input_tokens\":71,\"input_tokens_details\":{\"cache_write_tokens\":0,\"cached_tokens\":0},\"output_tokens\":34,\"output_tokens_details\":{\"reasoning_tokens\":11},\"total_tokens\":105},\"user\":null,\"metadata\":{}},\"sequence_number\":16}",
  ]
  // Low effort: function_call is the only output item (output_index 0).
  let acc = @posoco.StreamAccumulator::StreamAccumulator()
  let st = SseStreamState::SseStreamState()
  let mut terminal = false
  for ev in low {
    if process_responses_sse(provider="OpenAI", ev, acc, _ => (), state=st) {
      terminal = true
    }
  }
  assert_true(terminal)
  validate_stream_tool_calls(provider="OpenAI", acc)
  let completion = acc.to_completion()
  let tool_calls = completion.tool_calls()
  assert_eq(tool_calls.length(), 1)
  assert_eq(tool_calls[0].call_id.to_string(), "call_fixture000000000000000001")
  assert_eq(tool_calls[0].name.to_string(), "read")
  assert_eq(
    tool_calls[0].arguments.stringify(),
    "{\"path\":\"/tmp/notes.txt\"}",
  )
  assert_true(
    completion.message.finish_reason is @posoco.FinishReason::ToolCalls,
  )
  assert_eq(st.items.length(), 0)
  // Effort max: reasoning item at output_index 0, function_call at 1. Before
  // the remap this raised (stage=tool.id, category=missing) on turn one.
  let acc2 = @posoco.StreamAccumulator::StreamAccumulator()
  let st2 = SseStreamState::SseStreamState()
  let mut terminal2 = false
  for ev in max_effort {
    if process_responses_sse(provider="OpenAI", ev, acc2, _ => (), state=st2) {
      terminal2 = true
    }
  }
  assert_true(terminal2)
  validate_stream_tool_calls(provider="OpenAI", acc2)
  let completion2 = acc2.to_completion()
  let tool_calls2 = completion2.tool_calls()
  assert_eq(tool_calls2.length(), 1)
  assert_eq(tool_calls2[0].call_id.to_string(), "call_fixture000000000000000002")
  assert_eq(tool_calls2[0].name.to_string(), "read")
  assert_eq(
    tool_calls2[0].arguments.stringify(),
    "{\"path\":\"/tmp/notes.txt\"}",
  )
  assert_true(
    completion2.message.finish_reason is @posoco.FinishReason::ToolCalls,
  )
  // The reasoning item (with encrypted_content) is captured exactly once from
  // its done event, ready for verbatim replay on the next request.
  assert_eq(st2.items.length(), 1)
  match st2.items[0] {
    Json::Object(item) => assert_true(item.contains("encrypted_content"))
    _ => fail("captured reasoning item must be an object")
  }
}
