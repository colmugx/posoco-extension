///|
/// The authoritative V2 window is latest retained input + the new opaque
/// item, not the collection of streamed assistant/tool outputs.
fn compact_latest_fixture() -> Array[Json] raise {
  guard @json.parse(
      (
        #|[{"type":"message","role":"user","id":"msg_u","content":[{"type":"input_text","text":"plan the trip"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]},
        #| {"type":"compaction","id":"cmp_latest","encrypted_content":"gAAAA-state","extra":{"v":7}}]
      ),
    )
    is Json::Array(items) else {
    fail("fixture array")
  }
  items
}

///|
fn encode_window_input(messages : Array[@posoco.Message]) -> Array[Json] raise {
  openai_encode_window_items(messages)
}

///|
fn compact_test_anchor(
  payload : Json,
  content? : Array[@posoco.Content] = [],
) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content~,
    tool_calls=[],
    reasoning=Some({
      content: "",
      raw: Some(
        Json::object(Map::from_array([(compact_raw_envelope_key(), payload)])),
      ),
    }),
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
fn expect_compact_replay_parse_error(
  messages : Array[@posoco.Message],
  stage : String,
  category : String,
) -> Unit raise {
  let result = Ok(encode_window_input(messages)) catch { e => Err(e) }
  guard result is Err(@posoco.ModelError::ResponseParse(message)) else {
    fail("expected replay failure")
  }
  assert_true(message.contains("stage=" + stage))
  assert_true(message.contains("category=" + category))
  assert_false(message.contains("gAAAA"))
}

///|
test "openai_compact_latest_window_replays_original_fields_once" {
  let raw = compact_latest_fixture()
  let window = compact_latest_window(raw)
  assert_eq(window.length(), 3)
  assert_true(Json::array(encode_window_input(window)) == Json::array(raw))
  guard window[1] is @posoco.Message::UserMessage(content~) else {
    fail("retained user projection")
  }
  assert_true(content == [@posoco.Content::Text("plan the trip")])
  for item in encode_window_input(window) {
    guard item is Json::Object(fields) else { fail("wire item") }
    assert_false(fields.contains(compact_raw_envelope_key()))
  }
}

///|
test "openai_compact_latest_raw_persist_load_recompact" {
  let raw = compact_latest_fixture()
  let window = compact_latest_window(raw)
  guard window[0]
    is @posoco.Message::AssistantMessage(
      reasoning=Some({ raw: Some(envelope), .. }),
      ..
    ) else {
    fail("anchor")
  }
  let persisted = @json.parse(envelope.stringify())
  guard persisted is Json::Object(fields) else { fail("persisted envelope") }
  let resumed = compact_latest_window(raw)
  resumed[0] = compact_test_anchor(fields[compact_raw_envelope_key()])
  resumed.push(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("new turn")]),
  )
  let config = OpenAIConfig("k-test", "test-model")
  let (body, history) = build_compact_v2_request(
    config,
    resumed,
    [],
    { temperature: None, max_output_tokens: None, },
    "persist-session",
  )
  guard body is Json::Object(body_fields) &&
    body_fields.get("input") is Some(Json::Array(items)) else {
    fail("input")
  }
  assert_eq(items.length(), 4)
  assert_true(items[0] == raw[0] && items[1] == raw[1])
  assert_eq(items[3], @json.parse("{\"type\":\"compaction_trigger\"}"))
  let retained = compact_v2_retained_history(history)
  assert_eq(retained.length(), 2)
  let next = @json.parse(
    "{\"type\":\"compaction\",\"encrypted_content\":\"new-opaque\"}",
  )
  retained.push(next)
  let replay = encode_window_input(compact_latest_window(retained))
  assert_eq(replay.length(), 3)
  assert_true(replay[2] == next)
  assert_false(Json::array(replay).stringify().contains("gAAAA-state"))
}

///|
test "openai_compact_latest_projection_mutation_truncation_duplicate_fail" {
  let raw = compact_latest_fixture()
  let changed = compact_latest_window(raw)
  changed[1] = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("tampered"),
  ])
  expect_compact_replay_parse_error(changed, "projection", "mismatch")
  let truncated = compact_latest_window(raw)
  ignore(truncated.remove(truncated.length() - 1))
  expect_compact_replay_parse_error(truncated, "projection", "incomplete")
  let duplicate = compact_latest_window(raw)
  duplicate.push(duplicate[0])
  expect_compact_replay_parse_error(duplicate, "anchor", "duplicate")
}

///|
test "openai_compact_latest_corrupted_anchor_has_no_lossy_fallback" {
  for payload in [Json::null(), Json::array([]), Json::number(1)] {
    expect_compact_replay_parse_error(
      [compact_test_anchor(payload)],
      "anchor",
      "wrong_type",
    )
  }
  let raw = compact_latest_fixture()
  expect_compact_replay_parse_error(
    [
      compact_test_anchor(
        Json::object(
          Map::from_array([
            ("version", Json::number(2)),
            ("output", Json::array(raw)),
          ]),
        ),
      ),
    ],
    "anchor",
    "version",
  )
  expect_compact_replay_parse_error(
    [
      compact_test_anchor(
        Json::object(Map::from_array([("version", Json::number(1))])),
      ),
    ],
    "anchor",
    "missing_output",
  )
  expect_compact_replay_parse_error(
    [
      compact_test_anchor(
        Json::object(
          Map::from_array([
            ("version", Json::number(1)),
            ("output", Json::array([])),
          ]),
        ),
      ),
    ],
    "anchor",
    "empty_output",
  )
}

///|
test "openai_compact_latest_request_mutation_does_not_modify_anchor" {
  let raw = compact_latest_fixture()
  let window = compact_latest_window(raw)
  let before = Json::array(compact_anchor_output(window[0]).unwrap()).stringify()
  let encoded = encode_window_input(window)
  guard encoded[1] is Json::Object(item) else { fail("compaction") }
  item["encrypted_content"] = Json::string("changed")
  guard encoded[0] is Json::Object(user) &&
    user.get("content") is Some(Json::Array(parts)) &&
    parts[0] is Json::Object(text) else {
    fail("user")
  }
  text["text"] = Json::string("changed")
  assert_eq(
    Json::array(compact_anchor_output(window[0]).unwrap()).stringify(),
    before,
  )
  assert_true(Json::array(encode_window_input(window)) == Json::array(raw))
}

///|
/// Minimal provenance: wrapper-shaped user text is retained verbatim — a
/// real user may submit Codex harness text or a Cetas context envelope, so
/// no marker excludes an ordinary user message. Assistant/tool/old-compaction
/// stay excluded and the image-resize notice keeps its source user.
test "openai_compact_latest_retains_user_wrappers_mixed_images_not_assistant_tools" {
  guard @json.parse(
      (
        #|[{"role":"user","content":"old question"},
        #| {"role":"assistant","content":"old answer"},
        #| {"type":"function_call_output","call_id":"c","output":"old tool"},
        #| {"type":"compaction","encrypted_content":"old-state"},
        #| {"role":"user","content":"<environment_context>hidden</environment_context>"},
        #| {"role":"user","content":"<hook_prompt hook_run_id=\"hook-1\">retry carefully</hook_prompt>"},
        #| {"role":"user","content":"<cetas-context type=\"project_instructions\" trust=\"false\" source=\"/repo/AGENTS.md\">\nBuild with: moon test\n</cetas-context>"},
        #| {"role":"user","content":[{"type":"input_text","text":"see screenshot"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"}]},
        #| {"role":"user","content":"latest question"},
        #| {"role":"developer","content":[{"type":"input_text","text":"<image_resize_notice>resized</image_resize_notice>"}]}]
      ),
    )
    is Json::Array(history) else {
    fail("history")
  }
  let retained = compact_v2_retained_history(history)
  assert_eq(retained.length(), 7)
  assert_true(
    retained[0] == history[0] &&
    retained[1] == history[4] &&
    retained[2] == history[5] &&
    retained[3] == history[6] &&
    retained[4] == history[7] &&
    retained[5] == history[8] &&
    retained[6] == history[9],
  )
  let window = Json::array(retained).stringify()
  // Wrapper-shaped user text survives verbatim instead of being guessed away.
  assert_true(
    window.contains("<environment_context>hidden</environment_context>"),
  )
  assert_true(window.contains("hook_run_id=\\\"hook-1\\\""))
  assert_true(
    window.contains("<cetas-context type=\\\"project_instructions\\\""),
  )
  assert_true(window.contains("Build with: moon test"))
  // Mixed-image user messages stay intact under the default budget.
  assert_true(window.contains("see screenshot"))
  assert_true(window.contains("input_image"))
  assert_true(
    window.contains("<image_resize_notice>resized</image_resize_notice>"),
  )
  // Other roles and the previous opaque item are still dropped.
  assert_false(window.contains("old answer"))
  assert_false(window.contains("old tool"))
  assert_false(window.contains("old-state"))
}

///|
/// Wrapper text no longer special-cases retention in either direction: under
/// budget pressure a wrapper-shaped user truncates like any other message.
test "openai_compact_latest_user_wrapper_truncates_under_budget" {
  guard @json.parse(
      (
        #|[{"role":"user","content":"<environment_context>abcdefghijk</environment_context>"},
        #| {"role":"user","content":"new"}]
      ),
    )
    is Json::Array(history) else {
    fail("history")
  }
  let kept = compact_v2_retained_history(history, budget=3)
  assert_eq(kept.length(), 2)
  assert_true(kept[1] == history[1])
  assert_true(kept[0].stringify().contains("…12 tokens truncated…"))
}

///|
test "openai_compact_latest_64k_utf8_estimator_and_boundary_middle_truncation" {
  assert_eq(compact_retained_message_token_budget, 64_000)
  assert_eq(compact_approx_tokens("你好🙂"), 3)
  assert_eq(
    compact_truncate_text("abcdefghijk", 2),
    "abcd…1 tokens truncated…hijk",
  )
  guard @json.parse(
      "[{\"role\":\"user\",\"content\":\"old\"},{\"role\":\"user\",\"content\":\"abcdefghijk\"},{\"role\":\"user\",\"content\":\"new\"}]",
    )
    is Json::Array(history) else {
    fail("array")
  }
  let kept = compact_v2_retained_history(history, budget=3)
  assert_eq(kept.length(), 2)
  assert_true(kept[1] == history[2])
  assert_true(kept[0].stringify().contains("abcd…1 tokens truncated…hijk"))
}

///|
test "openai_compact_latest_opaque_only_has_no_fabricated_text" {
  let item = @json.parse(
    "{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"}",
  )
  let window = compact_latest_window([item])
  assert_eq(window.length(), 2)
  for message in window {
    guard message is @posoco.Message::AssistantMessage(content~, ..) else {
      fail("state only")
    }
    assert_true(content.is_empty())
  }
  assert_true(encode_window_input(window) == [item])
}
