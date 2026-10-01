///|
/// White-box tests for the OpenAI-private raw compact-window replay:
/// the standalone `/responses/compact` output array is stored verbatim in a
/// versioned envelope on a synthetic assistant anchor, and the shared input
/// encoder replays it exactly while skipping the shadow canonical projection.
///
/// `parse_compact_response` decodes the provider envelope into the anchored
/// window; `build_request_body` / `build_compact_request_body` are the real
/// serialized encoders under test.

///|
/// A realistic `/responses/compact` output window: opaque encrypted state,
/// retained user content (multi-modal), a reasoning item, an assistant
/// message with id/status, and function-call items with extra fields. Every
/// field here must survive a compact -> encode round trip byte-value-exact.
fn compact_raw_window_envelope() -> Json raise {
  let window =
    #|{"output":[
    #|  {"type":"compaction","id":"cmp_9","encrypted_content":"gAAAA-compaction-state"},
    #|  {"role":"user","content":[{"type":"input_text","text":"plan the trip"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]},
    #|  {"type":"reasoning","id":"rs_9","summary":[{"type":"summary_text","text":"thinking"}],"encrypted_content":"gAAAA-reasoning"},
    #|  {"type":"message","id":"msg_9","role":"assistant","status":"completed","content":[{"type":"output_text","text":"-3c in oslo","annotations":[]}]},
    #|  {"type":"function_call","id":"fc_9","call_id":"call_9","name":"get_weather","arguments":"{\"city\":\"oslo\"}","status":"completed"},
    #|  {"type":"function_call_output","id":"fco_9","call_id":"call_9","output":"-3c"}
    #|]}
  @json.parse(window)
}

///|
/// The output items of the fixture window.
fn compact_raw_window_items() -> Array[Json] raise {
  let items = match compact_raw_window_envelope() {
    Json::Object(fields) => fields.get("output")
    _ => None
  }
  match items {
    Some(Json::Array(arr)) => arr
    _ => fail("fixture must carry an output array")
  }
}

///|
/// The real encoder's `input` items for a message window.
fn encode_window_input(messages : Array[@posoco.Message]) -> Array[Json] raise {
  let body = build_request_body(
    messages,
    [],
    { temperature: None, max_output_tokens: None, },
    "gpt-5",
    None,
  )
  match body {
    Json::Object(fields) =>
      match fields.get("input") {
        Some(Json::Array(items)) => items
        _ => fail("expected input item array")
      }
    _ => fail("expected object body")
  }
}

///|
fn expect_compact_replay_parse_error(
  messages : Array[@posoco.Message],
  stage : String,
  category : String,
) -> Unit raise {
  let result = Ok(encode_window_input(messages)) catch { e => Err(e) }
  match result {
    Err(@posoco.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("stage=" + stage))
      assert_true(message.contains("category=" + category))
    }
    _ => fail("expected ResponseParse for \{stage}/\{category}")
  }
}

///|
test "openai_compact_window_replays_raw_output_items_exactly" {
  let expected_input = compact_raw_window_items()
  let window = parse_compact_response(compact_raw_window_envelope())
  let items = encode_window_input(window)
  // The authoritative window replays exactly: same items, same order, same
  // field values (encrypted_content, ids, status, extra function-call fields,
  // multi-modal user parts). Object-key order is not significant.
  assert_true(Json::array(items) == Json::array(expected_input))
  // The provider-private envelope must never leak onto the wire.
  for item in items {
    match item {
      Json::Object(item_fields) =>
        assert_false(item_fields.contains("posoco.openai.compact_raw_window"))
      _ => ()
    }
  }
}

///|
/// The anchor is a dedicated synthetic assistant: no fabricated content, and
/// the versioned envelope stores the original output array verbatim. The
/// canonical projection after the anchor keeps the retained user turn and
/// assistant text visible to user/activation/context consumers, so context
/// occupancy inputs stay real instead of collapsing to a single empty
/// assistant. No usage/occupancy value is synthesized anywhere.
test "openai_compact_anchor_keeps_canonical_projection_visible" {
  let window = parse_compact_response(compact_raw_window_envelope())
  assert_eq(window.length(), 6)
  match window[0] {
    @posoco.Message::AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
      // The anchor fabricates nothing: empty content (an honest, near-zero
      // estimator input) and only the opaque envelope as reasoning state.
      assert_eq(content.length(), 0)
      assert_eq(tool_calls.length(), 0)
      match reasoning {
        Some({ content: "", raw: Some(Json::Object(fields)), }) => {
          assert_true(fields.contains("posoco.openai.compact_raw_window"))
          // Persistence shape: the envelope is self-contained JSON that
          // survives a serialize/load cycle unchanged.
          let persisted = @json.parse(
            fields["posoco.openai.compact_raw_window"].stringify(),
          )
          assert_true(persisted == fields["posoco.openai.compact_raw_window"])
          match persisted {
            Json::Object(payload) => {
              match payload.get("version") {
                Some(Json::Number(v, ..)) => assert_eq(v, 1.0)
                _ => fail("envelope must be versioned")
              }
              match payload.get("output") {
                Some(Json::Array(stored)) =>
                  assert_true(
                    Json::array(stored) ==
                    Json::array(compact_raw_window_items()),
                  )
                _ => fail("envelope must store the output array")
              }
            }
            _ => fail("envelope payload must be an object")
          }
        }
        _ => fail("anchor must carry the versioned raw envelope")
      }
    }
    _ => fail("expected the synthetic anchor assistant at the window head")
  }
  // window[1] is the projection's own synthetic assistant carrying the
  // compaction state; the retained user turn follows it.
  match window[2] {
    @posoco.Message::UserMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(t) => assert_eq(t, "plan the trip")
        _ => fail("retained user text must stay visible to consumers")
      }
    _ => fail("expected the retained user message after the anchor")
  }
  match window[3] {
    @posoco.Message::AssistantMessage(content~, ..) =>
      match content[0] {
        @posoco.Content::Text(t) => assert_eq(t, "-3c in oslo")
        _ => fail("retained assistant text must stay visible to consumers")
      }
    _ => fail("expected the retained assistant message")
  }
}

///|
/// Recompact sends the window back through the same encoder: the stored raw
/// output replays, not the projection re-encoding.
test "openai_compact_recompact_uses_the_same_window_encoder" {
  let window = parse_compact_response(compact_raw_window_envelope())
  let body = build_compact_request_body(window, "gpt-5")
  guard body is Json::Object(fields) else { fail("expected object body") }
  match fields.get("input") {
    Some(Json::Array(items)) =>
      assert_true(Json::array(items) == Json::array(compact_raw_window_items()))
    _ => fail("expected input item array")
  }
}

///|
/// Messages appended after the validated projection encode normally; a
/// legacy bare reasoning.raw array on an appended assistant still replays
/// verbatim through the shared encoder.
test "openai_compact_appended_turns_encode_normally_after_raw_replay" {
  let window = parse_compact_response(compact_raw_window_envelope())
  let legacy_raw =
    #|{"id":"rs_new","type":"reasoning","summary":[],"encrypted_content":"gAAAA-new"}
  window.push(
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text("and the aurora?"),
    ]),
  )
  window.push(
    @posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("visible tonight")],
      tool_calls=[],
      reasoning=Some({
        content: "",
        raw: Some(Json::array([@json.parse(legacy_raw)])),
      }),
      finish_reason=@posoco.FinishReason::Stop,
    ),
  )
  let expected =
    #|[
    #| {"type":"compaction","id":"cmp_9","encrypted_content":"gAAAA-compaction-state"},
    #| {"role":"user","content":[{"type":"input_text","text":"plan the trip"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]},
    #| {"type":"reasoning","id":"rs_9","summary":[{"type":"summary_text","text":"thinking"}],"encrypted_content":"gAAAA-reasoning"},
    #| {"type":"message","id":"msg_9","role":"assistant","status":"completed","content":[{"type":"output_text","text":"-3c in oslo","annotations":[]}]},
    #| {"type":"function_call","id":"fc_9","call_id":"call_9","name":"get_weather","arguments":"{\"city\":\"oslo\"}","status":"completed"},
    #| {"type":"function_call_output","id":"fco_9","call_id":"call_9","output":"-3c"},
    #| {"role":"user","content":[{"type":"input_text","text":"and the aurora?"}]},
    #| {"id":"rs_new","type":"reasoning","summary":[],"encrypted_content":"gAAAA-new"},
    #| {"role":"assistant","content":[{"type":"output_text","text":"visible tonight"}]}
    #|]
  assert_true(Json::array(encode_window_input(window)) == @json.parse(expected))
}

///|
/// Legitimate host-prefixed context injection before the anchor encodes
/// normally ahead of the replayed raw window.
test "openai_compact_prepended_context_injection_before_anchor" {
  let injected : Array[@posoco.Message] = [
    @posoco.Message::SystemMessage(content=[
      @posoco.Content::Text("session preamble"),
    ]),
  ]
  for m in parse_compact_response(compact_raw_window_envelope()) {
    injected.push(m)
  }
  let expected =
    #|[
    #| {"role":"system","content":[{"type":"input_text","text":"session preamble"}]},
    #| {"type":"compaction","id":"cmp_9","encrypted_content":"gAAAA-compaction-state"},
    #| {"role":"user","content":[{"type":"input_text","text":"plan the trip"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]},
    #| {"type":"reasoning","id":"rs_9","summary":[{"type":"summary_text","text":"thinking"}],"encrypted_content":"gAAAA-reasoning"},
    #| {"type":"message","id":"msg_9","role":"assistant","status":"completed","content":[{"type":"output_text","text":"-3c in oslo","annotations":[]}]},
    #| {"type":"function_call","id":"fc_9","call_id":"call_9","name":"get_weather","arguments":"{\"city\":\"oslo\"}","status":"completed"},
    #| {"type":"function_call_output","id":"fco_9","call_id":"call_9","output":"-3c"}
    #|]
  assert_true(
    Json::array(encode_window_input(injected)) == @json.parse(expected),
  )
}

///|
/// The raw items replay exactly once: the shadow projection (including its
/// own reasoning.raw arrays) is skipped, never double-emitted.
test "openai_compact_raw_items_replay_exactly_once" {
  let items = encode_window_input(
    parse_compact_response(compact_raw_window_envelope()),
  )
  let mut compaction = 0
  let mut reasoning_rs9 = 0
  for item in items {
    match item {
      Json::Object(fields) => {
        match fields.get("type") {
          Some(Json::String("compaction")) => compaction += 1
          _ => ()
        }
        match fields.get("id") {
          Some(Json::String("rs_9")) => reasoning_rs9 += 1
          _ => ()
        }
      }
      _ => ()
    }
  }
  assert_eq(compaction, 1)
  assert_eq(reasoning_rs9, 1)
  assert_eq(items.length(), compact_raw_window_items().length())
}

///|
/// Host/user mutations of the projection after compaction are explicit
/// failures: never a silent stale raw replay, never a lossy fallback.
test "openai_compact_projection_mutation_fails_loudly" {
  let window = parse_compact_response(compact_raw_window_envelope())
  window[1] = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("tampered"),
  ])
  expect_compact_replay_parse_error(window, "projection", "mismatch")
}

///|
/// A truncated projection (dropped or not-yet-replayed messages) is an
/// explicit failure.
test "openai_compact_truncated_projection_fails_loudly" {
  let window = parse_compact_response(compact_raw_window_envelope())
  let dropped = window.remove(window.length() - 1)
  ignore(dropped)
  expect_compact_replay_parse_error(window, "projection", "incomplete")
  // An anchor with no projection messages at all is the same failure.
  let anchor_only : Array[@posoco.Message] = [
    @posoco.Message::AssistantMessage(
      content=[],
      tool_calls=[],
      reasoning=Some(compact_raw_anchor_reasoning(compact_raw_window_items())),
      finish_reason=@posoco.FinishReason::Stop,
    ),
  ]
  expect_compact_replay_parse_error(anchor_only, "projection", "incomplete")
}

///|
/// Corrupted anchors fail loudly instead of degrading silently.
test "openai_compact_corrupted_anchor_fails_loudly" {
  let items = compact_raw_window_items()
  // Visible content attached to the envelope.
  let with_content : Array[@posoco.Message] = [
    @posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("not empty")],
      tool_calls=[],
      reasoning=Some(compact_raw_anchor_reasoning(items)),
      finish_reason=@posoco.FinishReason::Stop,
    ),
  ]
  expect_compact_replay_parse_error(with_content, "anchor", "corrupted")
  // Unknown envelope version: this adapter replays only what it can verify.
  let future = Json::object(
    Map::from_array([
      ("version", Json::number(2)),
      ("output", Json::array(items.map(json_deep_copy))),
    ]),
  )
  let future_anchor : Array[@posoco.Message] = [
    @posoco.Message::AssistantMessage(
      content=[],
      tool_calls=[],
      reasoning=Some({
        content: "",
        raw: Some(
          Json::object(
            Map::from_array([("posoco.openai.compact_raw_window", future)]),
          ),
        ),
      }),
      finish_reason=@posoco.FinishReason::Stop,
    ),
  ]
  expect_compact_replay_parse_error(future_anchor, "anchor", "version")
  // Envelope without a stored output.
  let hollow : Array[@posoco.Message] = [
    @posoco.Message::AssistantMessage(
      content=[],
      tool_calls=[],
      reasoning=Some({
        content: "",
        raw: Some(
          Json::object(
            Map::from_array([
              (
                "posoco.openai.compact_raw_window",
                Json::object(Map::from_array([("version", Json::number(1))])),
              ),
            ]),
          ),
        ),
      }),
      finish_reason=@posoco.FinishReason::Stop,
    ),
  ]
  expect_compact_replay_parse_error(hollow, "anchor", "missing_output")
  // Two anchors in one window cannot both replay; that is a corrupt window.
  let anchor = fn() -> @posoco.Message {
    @posoco.Message::AssistantMessage(
      content=[],
      tool_calls=[],
      reasoning=Some(compact_raw_anchor_reasoning(items)),
      finish_reason=@posoco.FinishReason::Stop,
    )
  }
  let projected = parse_compact_response(compact_raw_window_envelope())
  let duplicated : Array[@posoco.Message] = [anchor(), anchor()]
  for m in projected {
    duplicated.push(m)
  }
  expect_compact_replay_parse_error(duplicated, "anchor", "duplicate")
}

///|
fn compact_test_anchor(
  payload : Json,
  content? : Array[@posoco.Content] = [],
  tool_calls? : Array[@posoco.ToolCall] = [],
) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content~,
    tool_calls~,
    reasoning=Some({
      content: "",
      raw: Some(
        Json::object(
          Map::from_array([("posoco.openai.compact_raw_window", payload)]),
        ),
      ),
    }),
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
test "openai_compact_output_without_call_id_uses_opaque_carrier_not_fake_tool" {
  let output =
    #|[{"type":"function_call_output","id":"fco_no_call","output":[{"type":"input_text","text":"retained result"}]},
    #| {"role":"user","content":"next"},
    #| {"type":"function_call_output","output":"also retained"}]
  let expected = @json.parse(output)
  let window = parse_compact_response(
    Json::object(Map::from_array([("output", expected)])),
  )
  assert_eq(window.length(), 4)
  for i in [1, 3] {
    match window[i] {
      @posoco.Message::AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
        assert_true(content.is_empty())
        assert_true(tool_calls.is_empty())
        guard reasoning is Some({ raw: Some(Json::Array(items)), .. }) else {
          fail("expected opaque carrier")
        }
        assert_eq(items.length(), 1)
        guard items[0] is Json::Object(fields) else {
          fail("expected retained output item")
        }
        assert_false(fields.contains("call_id"))
      }
      _ => fail("no canonical tool message without a real call ID")
    }
  }
  assert_true(Json::array(encode_window_input(window)) == expected)
  guard @json.parse(build_compact_request_body(window, "gpt-5").stringify())
    is Json::Object(fields) else {
    fail("expected serialized body")
  }
  assert_true(fields.get("input") == Some(expected))
  window[1] = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("changed"),
  ])
  expect_compact_replay_parse_error(window, "projection", "mismatch")
}

///|
test "openai_compact_image_file_only_content_is_visible_without_wire_placeholders" {
  let output =
    #|[{"role":"user","content":[{"type":"input_image","image_url":"https://example.test/image.png"}]},
    #| {"role":"user","content":[{"type":"input_file","file_id":"file_9"}]},
    #| {"type":"function_call_output","call_id":"c","output":[{"type":"input_image","file_id":"file_image"},{"type":"input_file","file_data":"AAAA","filename":"report.pdf"}]}]
  let expected = @json.parse(output)
  let window = parse_compact_response(
    Json::object(Map::from_array([("output", expected)])),
  )
  for
    i, display in [
      "[OpenAI compact image content]", "[OpenAI compact file content]",
    ] {
    match window[i + 1] {
      @posoco.Message::UserMessage(content~) =>
        assert_true(content == [@posoco.Content::Text(display)])
      _ => fail("expected retained user with explicit display placeholder")
    }
  }
  match window[3] {
    @posoco.Message::ToolMessage(
      outcome=@posoco.ToolOutcome::Success(content~, ..),
      ..
    ) =>
      assert_eq(
        content, "[OpenAI compact image content][OpenAI compact file content]",
      )
    _ => fail("expected tool display placeholders")
  }
  assert_true(Json::array(encode_window_input(window)) == expected)
  guard @json.parse(build_compact_request_body(window, "gpt-5").stringify())
    is Json::Object(fields) else {
    fail("expected serialized body")
  }
  assert_true(fields.get("input") == Some(expected))
}

///|
test "openai_compact_corrupted_stored_output_reports_replay_not_provider_parse" {
  for
    output in [
      Json::array([Json::number(9)]),
      @json.parse(
        "[{\"type\":\"function_call_output\",\"call_id\":\"c\",\"output\":{}}]",
      ),
      @json.parse("[{\"type\":\"function_call_output\",\"call_id\":\"c\"}]"),
      @json.parse("[{\"type\":\"function_call_output\",\"output\":[9]}]"),
      @json.parse(
        "[{\"type\":\"function_call_output\",\"output\":[{\"type\":\"input_text\",\"text\":9}]}]",
      ),
      @json.parse("[{\"role\":\"invalid\",\"content\":\"hidden payload\"}]"),
    ] {
    let anchor = compact_test_anchor(
      Json::object(
        Map::from_array([("version", Json::number(1)), ("output", output)]),
      ),
    )
    let result = Ok(encode_window_input([anchor])) catch { e => Err(e) }
    match result {
      Err(@posoco.ModelError::ResponseParse(message)) =>
        assert_eq(
          message, "OpenAI compact replay failure (stage=projection, category=invalid_output)",
        )
      _ => fail("corrupted stored output must fail replay validation")
    }
  }
}

///|
test "openai_compact_request_body_mutation_cannot_change_persisted_anchor" {
  let window = parse_compact_response(compact_raw_window_envelope())
  let persisted_before = Json::array(compact_anchor_output(window[0]).unwrap()).stringify()
  for
    body in [
      build_request_body(
        window,
        [],
        { temperature: None, max_output_tokens: None, },
        "gpt-5",
        None,
      ),
      build_compact_request_body(window, "gpt-5"),
    ] {
    guard body is Json::Object(fields) else { fail("expected object body") }
    guard fields.get("input") is Some(Json::Array(items)) else {
      fail("expected input array")
    }
    guard items[0] is Json::Object(state) else { fail("expected state object") }
    state.set("encrypted_content", Json::string("mutated"))
    guard items[1] is Json::Object(user) else { fail("expected user object") }
    guard user.get("content") is Some(Json::Array(parts)) else {
      fail("expected content array")
    }
    guard parts[0] is Json::Object(text) else { fail("expected text object") }
    text.set("text", Json::string("mutated"))
    parts.push(Json::null())
    assert_eq(
      Json::array(compact_anchor_output(window[0]).unwrap()).stringify(),
      persisted_before,
    )
    assert_true(
      Json::array(encode_window_input(window)) ==
      Json::array(compact_raw_window_items()),
    )
  }
}

///|
test "openai_compact_array_tool_output_projects_display_but_serializes_original_parts" {
  // openai/openai-python 157ac4c49a34891d5b66d2950b5082d1b3268315:
  // FunctionCallOutput.output is str | ResponseFunctionCallOutputItemListParam.
  let input =
    #|[{"type":"function_call_output","id":"fco_parts","call_id":"call_parts","output":[
    #| {"type":"input_text","text":"sunny"},
    #| {"type":"input_image","image_url":"data:image/png;base64,AAAA","detail":"auto"},
    #| {"type":"input_file","file_id":"file_9"}
    #|]}]
  let expected = @json.parse(input)
  let window = parse_compact_response(
    Json::object(Map::from_array([("output", expected)])),
  )
  match window[1] {
    @posoco.Message::ToolMessage(call_id~, outcome~, ..) => {
      assert_eq(call_id.to_string(), "call_parts")
      match outcome {
        @posoco.ToolOutcome::Success(content~, ..) => {
          assert_true(content.contains("sunny"))
          assert_true(content.contains("[OpenAI compact image content]"))
          assert_true(content.contains("[OpenAI compact file content]"))
        }
        _ => fail("expected canonical tool display")
      }
    }
    _ => fail("expected canonical tool message")
  }
  // Serialize and parse the actual bodies: output must remain an array, not
  // a JSON string or display-placeholder text, for chat AND recompact.
  let bodies = [
    build_request_body(
      window,
      [],
      { temperature: None, max_output_tokens: None, },
      "gpt-5",
      None,
    ),
    build_compact_request_body(window, "gpt-5"),
  ]
  for body in bodies {
    guard @json.parse(body.stringify()) is Json::Object(fields) else {
      fail("expected serialized body object")
    }
    assert_true(fields.get("input") == Some(expected))
  }
}

///|
test "openai_compact_nonobject_marker_never_falls_back_to_lossy_encoding" {
  for
    payload in [
      Json::null(),
      Json::string("broken"),
      Json::number(1),
      Json::boolean(false),
      Json::array([]),
    ] {
    expect_compact_replay_parse_error(
      [compact_test_anchor(payload)],
      "anchor",
      "wrong_type",
    )
    expect_compact_replay_parse_error(
      [compact_test_anchor(payload, content=[@posoco.Content::Text("changed")])],
      "anchor",
      "corrupted",
    )
    expect_compact_replay_parse_error(
      [
        compact_test_anchor(payload, tool_calls=[
          {
            call_id: @posoco.CallId::unchecked("call_changed"),
            name: @posoco.ToolName::unchecked("changed"),
            arguments: Json::null(),
          },
        ]),
      ],
      "anchor",
      "corrupted",
    )
  }
}

///|
/// [] output stays []: no anchor exists, the empty-window guard still fails,
/// and the encoder emits nothing.
test "openai_compact_empty_output_never_becomes_anchor" {
  let parsed = parse_compact_response(@json.parse("{\n  \"output\": []\n}"))
  assert_eq(parsed.length(), 0)
  let request : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("q1")]),
  ]
  let result = Ok(validate_compact_window(request, parsed)) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.ModelError::ResponseParse(msg)) =>
      assert_true(msg.contains("category=empty_window"))
    _ => fail("empty window for a non-empty session must raise")
  }
  assert_eq(encode_window_input(parsed).length(), 0)
}

///|
/// Without an anchor the shared encoder behaves exactly like the previous
/// per-message encoding: legacy reasoning.raw arrays replay verbatim.
test "openai_compact_encoder_keeps_legacy_reasoning_arrays_replay" {
  let raw_item =
    #|{"id":"rs_chat","type":"reasoning","summary":[],"encrypted_content":"gAAAA-chat"}
  let window : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hi")]),
    @posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("hello")],
      tool_calls=[],
      reasoning=Some({
        content: "",
        raw: Some(Json::array([@json.parse(raw_item)])),
      }),
      finish_reason=@posoco.FinishReason::Stop,
    ),
  ]
  let expected =
    #|[
    #| {"role":"user","content":[{"type":"input_text","text":"hi"}]},
    #| {"id":"rs_chat","type":"reasoning","summary":[],"encrypted_content":"gAAAA-chat"},
    #| {"role":"assistant","content":[{"type":"output_text","text":"hello"}]}
    #|]
  assert_true(Json::array(encode_window_input(window)) == @json.parse(expected))
}

///|
/// An opaque-only compact output (only encrypted state) still yields a
/// nonzero canonical window — never a single-empty-assistant-only collapse —
/// and the encoder replays the opaque item verbatim. The anchor fabricates no
/// content or usage: occupancy stays honestly unknown until the next model
/// step reports real usage.
test "openai_compact_opaque_only_output_stays_nonzero_and_honest" {
  let envelope =
    #|{"output":[{"type":"compaction","id":"cmp_only","encrypted_content":"gAAAA-only"}]}
  let window = parse_compact_response(@json.parse(envelope))
  // Anchor + the projection's synthetic state assistant: two messages, both
  // content-free, no fabricated usage anywhere.
  assert_eq(window.length(), 2)
  for m in window {
    match m {
      @posoco.Message::AssistantMessage(content~, ..) =>
        assert_eq(content.length(), 0)
      _ => fail("opaque-only window must contain only stateless assistants")
    }
  }
  let expected =
    #|[{"type":"compaction","id":"cmp_only","encrypted_content":"gAAAA-only"}]
  assert_true(Json::array(encode_window_input(window)) == @json.parse(expected))
}
