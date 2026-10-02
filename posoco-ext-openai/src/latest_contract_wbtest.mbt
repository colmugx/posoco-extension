///|
fn compact_v2_success_sse() -> String {
  "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"compaction\",\"id\":\"cmp_fixture\",\"encrypted_content\":\"opaque-fixture\",\"metadata\":{\"v\":2}}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fixture\",\"status\":\"completed\"}}\n\n"
}

///|
fn latest_fixture_tools() -> Array[@posoco.ToolDef] {
  [
    {
      name: @posoco.ToolName::unchecked("current_tool"),
      description: "current schema",
      input_schema: Json::object(
        Map::from_array([("type", Json::string("object"))]),
      ),
      owner: @posoco.OwnerId::unchecked("test"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: None,
    },
  ]
}

///|
async test "openai_compact_latest_loopback_bad_sse_is_safe_and_explicit_retry_succeeds" {
  let item = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"compaction\",\"encrypted_content\":\"encrypted-secret\"}}\n\n"
  let completed = "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fixture\",\"status\":\"completed\"}}\n\n"
  let bad_streams = [
    "data: {BAD_JSON_Bearer_sk-secret\n\n",
    item,
    completed,
    item + item + completed,
    "data: {\"type\":\"response.output_item.done\"}\n\n" + completed,
    "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"compaction\"}}\n\n" +
    completed,
    "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"context_compaction\",\"encrypted_content\":\"encrypted-secret\"}}\n\n" +
    completed,
    "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"Bearer_sk-secret_transcript\"}}}\n\n",
    item + "data: [DONE]\n\n",
    item +
    "data: {\"type\":\"response.incomplete\",\"response\":{\"incomplete_details\":{\"reason\":\"interrupted\"}}}\n\n",
  ]
  let replies : Array[CompactReply] = []
  for body in bad_streams {
    replies.push(
      Respond(
        status=200,
        body~,
        headers=[("Content-Type", "text/event-stream")],
        delay_ms=0,
      ),
    )
    replies.push(LatestV2Route)
  }
  let (outcomes, server) = @async.with_timeout(20000, () => {
    compact_loopback_call_many(replies)
  })
  assert_eq(server.requests.length(), bad_streams.length() * 2)
  for i in 0..<bad_streams.length() {
    guard outcomes[i * 2] is Err(@posoco.ModelError::ResponseParse(message)) else {
      fail("bad stream must fail")
    }
    assert_false(message.contains("sk-secret"))
    assert_false(message.contains("encrypted-secret"))
    assert_false(message.contains("transcript"))
    guard outcomes[i * 2 + 1] is Ok(_) else {
      fail("explicit retry must succeed")
    }
  }
}

///|
async test "openai_compact_latest_extra_output_is_not_installed" {
  let body = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"not retained\"}]}}\n\n" +
    compact_v2_success_sse()
  let (result, _) = compact_loopback_call(
    Respond(status=200, body~, headers=[], delay_ms=0),
  )
  guard result is Ok(result) else {
    fail("extra output permitted by collector")
  }
  let input = openai_encode_window_items(result.compacted_messages)
  assert_eq(input.length(), 2)
  assert_false(Json::array(input).stringify().contains("not retained"))
  assert_true(Json::array(input).stringify().contains("opaque-fixture"))
}

///|
async test "openai_compact_latest_first_manual_and_auto_carry_current_tools_effort_instructions" {
  let server = CompactLoopback::bind([LatestV2Route, LatestV2Route])
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      defer server.stop()
      let _ = group.spawn(() => server.serve(), allow_failure=true)
      let config = OpenAIConfig::with_base_url(
        "k-test",
        "declared-model",
        "http://127.0.0.1:\{server.server.addr.port()}/v1",
      ).with_reasoning_effort("high")
      let model : &@posoco.ModelPort = OpenAIModelPort(config)
      let messages : Array[@posoco.Message] = [
        @posoco.Message::SystemMessage(content=[
          @posoco.Content::Text("current instructions"),
        ]),
        @posoco.Message::UserMessage(content=[
          @posoco.Content::Text("current question"),
        ]),
      ]
      for
        trigger in [
          @posoco.CompactTrigger::Manual,
          @posoco.CompactTrigger::Auto,
        ] {
        let _ = model.compact(
          compact_loopback_scope(),
          messages,
          latest_fixture_tools(),
          { temperature: Some(0.0), max_output_tokens: Some(2048), },
          trigger,
        )
      }
    }
  })
  assert_eq(server.requests.length(), 2)
  for i in 0..<2 {
    assert_eq(server.requests[i].path, "/v1/responses")
    assert_eq(
      server.requests[i].headers.get("Accept"),
      Some("text/event-stream"),
    )
    guard @json.parse(server.bodies[i]) is Json::Object(fields) else {
      fail("body")
    }
    assert_eq(fields.get("model"), Some(Json::string("declared-model")))
    assert_eq(
      fields.get("instructions"),
      Some(Json::string("current instructions")),
    )
    assert_eq(
      fields.get("tools"),
      Some(
        Json::array(
          latest_fixture_tools().map(@responses.tool_to_responses_wire),
        ),
      ),
    )
    assert_eq(fields.get("temperature"), None)
    assert_eq(fields.get("max_output_tokens"), Some(Json::number(2048)))
    guard fields.get("reasoning") is Some(Json::Object(reasoning)) else {
      fail("reasoning")
    }
    assert_eq(reasoning.get("effort"), Some(Json::string("high")))
  }
}

///|
test "openai_compact_latest_lite_shape_chat_and_compact_match_metadata_not_slug" {
  let config = {
    ..OpenAIConfig("k-test", "non-hardcoded-model"),
    use_responses_lite: true,
    reasoning_effort: Some("medium"),
  }
  let messages : Array[@posoco.Message] = [
    @posoco.Message::SystemMessage(content=[
      @posoco.Content::Text("current instructions"),
    ]),
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("question")]),
  ]
  let (body, history) = build_compact_v2_request(
    config,
    messages,
    latest_fixture_tools(),
    { temperature: None, max_output_tokens: None, },
    "lite-session",
  )
  guard body is Json::Object(fields) &&
    fields.get("input") is Some(Json::Array(input)) else {
    fail("body")
  }
  assert_eq(input.length(), 4)
  guard input[0] is Json::Object(additional) else { fail("tools") }
  assert_eq(additional.get("type"), Some(Json::string("additional_tools")))
  assert_eq(
    additional.get("tools"),
    Some(
      Json::array(latest_fixture_tools().map(@responses.tool_to_responses_wire)),
    ),
  )
  assert_false(fields.contains("tools"))
  assert_eq(fields.get("instructions"), None)
  assert_eq(fields.get("parallel_tool_calls"), Some(Json::boolean(false)))
  guard fields.get("reasoning") is Some(Json::Object(reasoning)) else {
    fail("reasoning")
  }
  assert_eq(reasoning.get("context"), Some(Json::string("all_turns")))
  assert_eq(reasoning.get("effort"), Some(Json::string("medium")))
  assert_eq(history.length(), 1)
  assert_eq(
    build_headers(config, Some("lite-session"), true).get(
      "x-openai-internal-codex-responses-lite",
    ),
    Some("true"),
  )
  let (retry, _) = build_compact_v2_request(
    config,
    messages,
    latest_fixture_tools(),
    { temperature: None, max_output_tokens: None, },
    "lite-session",
  )
  assert_true(body == retry)
  let chat = openai_prepare_request(
    config,
    "lite-session",
    messages,
    latest_fixture_tools(),
    { temperature: None, max_output_tokens: None, },
    stream=true,
  )
  guard chat is Json::Object(chat_fields) &&
    chat_fields.get("input") is Some(Json::Array(chat_input)) else {
    fail("chat")
  }
  // Chat and compact share the Lite encoding: same prefix items, derived
  // from the session and payload only (never the model slug).
  assert_eq(chat_input.length(), 3)
  for i in 0..<3 {
    assert_true(chat_input[i] == input[i])
  }
  let normal = OpenAIConfig("k-test", "non-hardcoded-model")
  assert_false(normal.use_responses_lite)
  assert_eq(
    build_headers(normal, None, true).get(
      "x-openai-internal-codex-responses-lite",
    ),
    None,
  )
}

///|
/// use_responses_lite=false: chat and compact share the ordinary encoding —
/// base instructions at the top-level `instructions` field, current tools at
/// the top-level `tools` field — and the compact request differs only by the
/// single trailing `compaction_trigger` request control.
test "openai_request_preparation_false_branch_shares_instructions_tools_trigger" {
  let config = {
    ..OpenAIConfig("k-test", "wire-model"),
    reasoning_effort: Some("high"),
  }
  let messages : Array[@posoco.Message] = [
    @posoco.Message::SystemMessage(content=[
      @posoco.Content::Text("base instructions"),
    ]),
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("question")]),
  ]
  let options : @posoco.ChatOptions = {
    temperature: None,
    max_output_tokens: None,
  }
  let chat = openai_prepare_request(
    config,
    "session-false",
    messages,
    latest_fixture_tools(),
    options,
    stream=true,
  )
  guard chat is Json::Object(chat_fields) &&
    chat_fields.get("input") is Some(Json::Array(chat_input)) else {
    fail("chat body")
  }
  assert_eq(
    chat_fields.get("instructions"),
    Some(Json::string("base instructions")),
  )
  assert_eq(
    chat_fields.get("tools"),
    Some(
      Json::array(latest_fixture_tools().map(@responses.tool_to_responses_wire)),
    ),
  )
  // Lifted base instructions no longer ride as an input item.
  for item in chat_input {
    guard item is Json::Object(fields) else { fail("wire item") }
    assert_false(fields.get("role") == Some(Json::string("system")))
  }
  let (compact, history) = build_compact_v2_request(
    config,
    messages,
    latest_fixture_tools(),
    options,
    "session-false",
  )
  guard compact is Json::Object(compact_fields) &&
    compact_fields.get("input") is Some(Json::Array(compact_input)) else {
    fail("compact body")
  }
  assert_eq(compact_fields.get("instructions"), chat_fields.get("instructions"))
  assert_eq(compact_fields.get("tools"), chat_fields.get("tools"))
  // Exactly one trigger, appended after the shared input items.
  assert_eq(compact_input.length(), chat_input.length() + 1)
  for i in 0..<chat_input.length() {
    assert_true(compact_input[i] == chat_input[i])
  }
  assert_eq(
    compact_input[compact_input.length() - 1],
    @json.parse("{\"type\":\"compaction_trigger\"}"),
  )
  let mut triggers = 0
  for item in compact_input {
    if item is Json::Object(fields) &&
      fields.get("type") == Some(Json::string("compaction_trigger")) {
      triggers += 1
    }
  }
  assert_eq(triggers, 1)
  // The retained snapshot excludes the trigger; chat never sends one.
  assert_eq(history.length(), 1)
  assert_false(
    Json::array(chat_input).stringify().contains("compaction_trigger"),
  )
}

///|
/// Empty tool sets are a legitimate agent shape: the ordinary branch omits
/// the top-level `tools` field in both chat and compact instead of sending
/// an empty array, while the Lite branch still prefixes the empty
/// `additional_tools` item — the same shape chat sends for the model.
test "openai_request_preparation_empty_tools_omit_field_both_formats" {
  let messages : Array[@posoco.Message] = [
    @posoco.Message::SystemMessage(content=[
      @posoco.Content::Text("base instructions"),
    ]),
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("question")]),
  ]
  let options : @posoco.ChatOptions = {
    temperature: None,
    max_output_tokens: None,
  }
  let normal = OpenAIConfig("k-test", "wire-model")
  let (compact, _) = build_compact_v2_request(
    normal,
    messages,
    [],
    options,
    "session-empty",
  )
  guard compact is Json::Object(fields) else { fail("compact body") }
  assert_false(fields.contains("tools"))
  assert_eq(fields.get("instructions"), Some(Json::string("base instructions")))
  let chat = openai_prepare_request(
    normal,
    "session-empty",
    messages,
    [],
    options,
  )
  guard chat is Json::Object(chat_fields) else { fail("chat body") }
  assert_false(chat_fields.contains("tools"))
  assert_eq(chat_fields.get("instructions"), fields.get("instructions"))
  // Lite: the empty tool set still rides the developer additional_tools
  // prefix item, and the instructions move into the developer message.
  let lite = {
    ..OpenAIConfig("k-test", "wire-model"),
    use_responses_lite: true,
  }
  let (lite_compact, _) = build_compact_v2_request(
    lite,
    messages,
    [],
    options,
    "session-empty",
  )
  guard lite_compact is Json::Object(lite_fields) &&
    lite_fields.get("input") is Some(Json::Array(lite_input)) else {
    fail("lite compact body")
  }
  assert_false(lite_fields.contains("tools"))
  assert_false(lite_fields.contains("instructions"))
  guard lite_input[0] is Json::Object(additional) else { fail("tools prefix") }
  assert_eq(additional.get("type"), Some(Json::string("additional_tools")))
  assert_eq(additional.get("tools"), Some(Json::array([])))
  guard lite_input[1] is Json::Object(developer) else {
    fail("instructions message")
  }
  assert_eq(developer.get("role"), Some(Json::string("developer")))
  assert_eq(lite_fields.get("parallel_tool_calls"), Some(Json::boolean(false)))
  let lite_chat = openai_prepare_request(
    lite,
    "session-empty",
    messages,
    [],
    options,
  )
  guard lite_chat is Json::Object(lite_chat_fields) &&
    lite_chat_fields.get("input") is Some(Json::Array(lite_chat_input)) else {
    fail("lite chat body")
  }
  assert_true(lite_chat_input[0] == lite_input[0])
  assert_true(lite_chat_input[1] == lite_input[1])
}

///|
/// The shared preparation preserves the lossless opaque replay: the compact
/// window's stored items replay verbatim exactly once in both request paths,
/// envelope markers never reach the wire, and the trigger lands after the
/// replayed items without entering the retained snapshot.
test "openai_request_preparation_opaque_replay_verbatim_single_trigger" {
  let fixture = compact_latest_fixture()
  let window = compact_latest_window(fixture)
  window.push(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("follow-up")]),
  )
  let normal = OpenAIConfig("k-test", "wire-model")
  let options : @posoco.ChatOptions = {
    temperature: None,
    max_output_tokens: None,
  }
  let chat = openai_prepare_request(
    normal,
    "replay-session",
    window,
    latest_fixture_tools(),
    options,
  )
  guard chat is Json::Object(chat_fields) &&
    chat_fields.get("input") is Some(Json::Array(chat_input)) else {
    fail("chat body")
  }
  assert_eq(chat_input.length(), 3)
  assert_true(chat_input[0] == fixture[0])
  assert_true(chat_input[1] == fixture[1])
  assert_false(
    Json::array(chat_input).stringify().contains(compact_raw_envelope_key()),
  )
  assert_false(
    Json::array(chat_input).stringify().contains("compaction_trigger"),
  )
  let (compact, history) = build_compact_v2_request(
    normal,
    window,
    latest_fixture_tools(),
    options,
    "replay-session",
  )
  guard compact is Json::Object(compact_fields) &&
    compact_fields.get("input") is Some(Json::Array(compact_input)) else {
    fail("compact body")
  }
  assert_eq(compact_input.length(), 4)
  for i in 0..<3 {
    assert_true(compact_input[i] == chat_input[i])
  }
  assert_eq(compact_input[3], @json.parse("{\"type\":\"compaction_trigger\"}"))
  assert_eq(history.length(), 3)
  assert_false(Json::array(history).stringify().contains("compaction_trigger"))
  // The retained snapshot keeps the real user turns, so installing the new
  // opaque item replays the same encoded window on the next chat/recompact.
  let retained = compact_v2_retained_history(history)
  assert_eq(retained.length(), 2)
}

///|
test "openai_compact_latest_images_charge_budget_and_keep_labels_atomic" {
  guard @json.parse(
      (
        #|[{"role":"user","content":"old"}, {"role":"user","content":[{"type":"input_text","text":"prefix"},{"type":"input_text","text":"<image>"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"},{"type":"input_text","text":"</image>"},{"type":"input_text","text":"latest"}]}]
      ),
    )
    is Json::Array(history) else {
    fail("history")
  }
  assert_eq(
    compact_content_tokens(
      @json.parse("{\"type\":\"input_image\",\"image_url\":\"url\"}"),
    ),
    1844,
  )
  let retained = compact_v2_retained_history(history, budget=4)
  assert_eq(retained.length(), 1)
  assert_false(Json::array(retained).stringify().contains("input_image"))
  assert_false(Json::array(retained).stringify().contains("<image>"))
  assert_false(Json::array(retained).stringify().contains("prefix"))
  assert_true(Json::array(retained).stringify().contains("latest"))
}

///|
async test "openai_compact_latest_production_port_raw_persist_chat_recompact" {
  let chat_sse = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"next answer\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"total_tokens\":12}}}\n\n"
  let server = CompactLoopback::bind([
    LatestV2Route,
    Respond(status=200, body=chat_sse, headers=[], delay_ms=0),
    Respond(status=200, body=compact_v2_success_sse(), headers=[], delay_ms=0),
  ])
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      defer server.stop()
      let _ = group.spawn(() => server.serve(), allow_failure=true)
      let model : &@posoco.ModelPort = compact_loopback_port(
        "http://127.0.0.1:\{server.server.addr.port()}/v1",
      )
      let options : @posoco.ChatOptions = {
        temperature: None,
        max_output_tokens: None,
      }
      let original : Array[@posoco.Message] = [
        @posoco.Message::UserMessage(content=[
          @posoco.Content::Text("kept question"),
        ]),
        @posoco.Message::AssistantMessage(
          content=[@posoco.Content::Text("old assistant must disappear")],
          tool_calls=[],
          reasoning=None,
          finish_reason=@posoco.FinishReason::Stop,
        ),
      ]
      let compacted = model.compact(
          compact_loopback_scope(),
          original,
          latest_fixture_tools(),
          options,
          @posoco.CompactTrigger::Manual,
        ).compacted_messages
      guard compacted[0]
        is @posoco.Message::AssistantMessage(
          reasoning=Some({ raw: Some(envelope), .. }),
          ..
        ) else {
        fail("raw anchor")
      }
      guard @json.parse(envelope.stringify()) is Json::Object(persisted) else {
        fail("persisted envelope")
      }
      compacted[0] = compact_test_anchor(persisted[compact_raw_envelope_key()])
      compacted.push(
        @posoco.Message::UserMessage(content=[
          @posoco.Content::Text("follow-up question"),
        ]),
      )
      let chat = model.chat(
        compact_loopback_scope(),
        compacted,
        latest_fixture_tools(),
        options,
        @posoco.StreamMode::Stream(fn(_chunk) { () }),
      )
      assert_true(
        chat.completion.message.content ==
        [@posoco.Content::Text("next answer")],
      )
      let result = model.compact(
        compact_loopback_scope(),
        compacted,
        latest_fixture_tools(),
        options,
        @posoco.CompactTrigger::Auto,
      )
      let final_input = Json::array(
        openai_encode_window_items(result.compacted_messages),
      ).stringify()
      assert_true(
        final_input.contains("kept question") &&
        final_input.contains("follow-up question") &&
        final_input.contains("opaque-fixture"),
      )
      assert_false(final_input.contains("opaque-latest"))
    }
  })
  assert_eq(server.requests.length(), 3)
  for i in 0..<3 {
    assert_eq(server.requests[i].path, "/v1/responses")
  }
  for i in [1, 2] {
    assert_true(server.bodies[i].contains("opaque-latest"))
    assert_false(server.bodies[i].contains("old assistant must disappear"))
    assert_false(server.bodies[i].contains(compact_raw_envelope_key()))
  }
  assert_false(server.bodies[1].contains("compaction_trigger"))
  assert_true(server.bodies[2].contains("compaction_trigger"))
}

///|
async test "openai_compact_latest_cached_lite_survives_effort_and_key_rebuild" {
  let server = CompactLoopback::bind([LatestV2Route])
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      defer server.stop()
      let _ = group.spawn(() => server.serve(), allow_failure=true)
      let config = OpenAIConfig::with_base_url(
        "k-test",
        "cached-model",
        "http://127.0.0.1:\{server.server.addr.port()}/v1",
      )
      let records = @json.parse(
        "[{\"model_id\":\"cached-model\",\"thinking_efforts\":[\"medium\",\"high\"],\"default_effort\":\"medium\",\"context_window\":200000,\"use_responses_lite\":true}]",
      )
      let models = parse_cached_openai_models(Some(records)).unwrap()
      let catalog = OpenAIModelPort(config).model_catalog_from_cached_models(
        models,
        chatgpt_mode=false,
      )
      let slot = catalog.slots()[0]
      assert_true(slot.capabilities.contains("use_responses_lite"))
      let effort_slot = slot.rebuild_on_effort.unwrap()("high")
      let refreshed = effort_slot.rebuild_on_api_key.unwrap()(
        @oauth.ApiKeyCredential::ApiKeyCredential(secret="k-refreshed-test"),
      )
      assert_true(refreshed.capabilities.contains("use_responses_lite"))
      assert_eq(refreshed.port.provider_config().context_window, Some(200000))
      let _ = refreshed.port.compact(
        compact_loopback_scope(),
        compact_loopback_messages(),
        latest_fixture_tools(),
        { temperature: None, max_output_tokens: None, },
        @posoco.CompactTrigger::Manual,
      )
    }
  })
  assert_eq(
    server.requests[0].headers.get("x-openai-internal-codex-responses-lite"),
    Some("true"),
  )
  assert_eq(
    server.requests[0].headers.get("Authorization"),
    Some("Bearer k-refreshed-test"),
  )
  guard @json.parse(server.bodies[0]) is Json::Object(fields) &&
    fields.get("reasoning") is Some(Json::Object(reasoning)) else {
    fail("reasoning")
  }
  assert_eq(reasoning.get("effort"), Some(Json::string("high")))
  assert_false(fields.contains("tools"))
  let missing = parse_cached_openai_models(
    Some(@json.parse("[{\"model_id\":\"cached-model\"}]")),
  ).unwrap()
  assert_false(missing[0].use_responses_lite)
  let discovered = parse_codex_models(
    @json.parse(
      "{\"models\":[{\"slug\":\"any-model\",\"display_name\":\"any\",\"supported_reasoning_levels\":[],\"visibility\":\"list\",\"supported_in_api\":true,\"priority\":1}]}",
    ),
  )
  assert_false(discovered[0].use_responses_lite)
}
