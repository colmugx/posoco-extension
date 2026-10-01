///|
// Hand-built OpenAI-private fixture: fs-session treats the envelope as opaque
// JSON, without depending on the OpenAI adapter or decoding encrypted state.
fn compact_replay_fixture() -> (Json, @posoco.Session) raise {
  let source =
    #|{"posoco.openai.compact_raw_window":{"version":1,"output":[
    #|  {"type":"message","id":"msg_user","role":"user","status":"completed","content":[{"type":"input_text","text":"Keep the first user request."}]},
    #|  {"type":"message","id":"msg_activation","role":"developer","status":"completed","content":[{"type":"input_text","text":"profile coder activated\nUse the read tool."}]},
    #|  {"type":"compaction","id":"cmp_fixture","encrypted_content":"cipher+compaction/==\nopaque\\state\"雪"},
    #|  {"type":"reasoning","id":"rs_fixture","status":"completed","summary":[{"type":"summary_text","text":"Inspect the file."}],"encrypted_content":"cipher+reasoning/=="},
    #|  {"type":"message","id":"msg_assistant","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Reading the file.","annotations":[]}]},
    #|  {"type":"function_call","id":"fc_fixture","call_id":"call_fixture","name":"read","arguments":"{\"path\":\"src/main.mbt\",\"limit\":2}","status":"completed"},
    #|  {"type":"function_call_output","id":"fco_fixture","call_id":"call_fixture","output":"line 1\nline 2"}
    #|]}}
  let raw = @json.parse(source)
  guard raw is Json::Object(fields) else { fail("expected raw object fixture") }
  guard fields["posoco.openai.compact_raw_window"] is Json::Object(payload) else {
    fail("expected compact envelope fixture")
  }
  guard payload["output"] is Json::Array(output) else {
    fail("expected output fixture")
  }
  // Literal canonical projection of the fixture, including the projection's
  // legacy raw state array alongside the dedicated Object-envelope anchor.
  let session = @posoco.Session::{
    messages: [
      @posoco.Message::AssistantMessage(
        content=[],
        tool_calls=[],
        reasoning=Some({ content: "", raw: Some(raw), }),
        finish_reason=@posoco.FinishReason::Stop,
      ),
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text("Keep the first user request."),
      ]),
      @posoco.Message::SystemMessage(content=[
        @posoco.Content::Text("profile coder activated\nUse the read tool."),
      ]),
      @posoco.Message::AssistantMessage(
        content=[@posoco.Content::Text("Reading the file.")],
        tool_calls=[],
        reasoning=Some({
          content: "",
          raw: Some(Json::array([output[2], output[3]])),
        }),
        finish_reason=@posoco.FinishReason::Stop,
      ),
      @posoco.Message::AssistantMessage(
        content=[],
        tool_calls=[
          {
            call_id: @posoco.CallId::unchecked("call_fixture"),
            name: @posoco.ToolName::unchecked("read"),
            arguments: @json.parse("{\"path\":\"src/main.mbt\",\"limit\":2}"),
          },
        ],
        reasoning=None,
        finish_reason=@posoco.FinishReason::ToolCalls,
      ),
      @posoco.Message::ToolMessage(
        call_id=@posoco.CallId::unchecked("call_fixture"),
        tool_name=@posoco.ToolName::unchecked(""),
        outcome=@posoco.ToolOutcome::Success(
          content="line 1\nline 2",
          structured=None,
        ),
      ),
    ],
    metadata: Map::from_array([("fixture", Json::string("compact-replay"))]),
  }
  (raw, session)
}

///|
fn assert_compact_replay_preserved(
  loaded : @posoco.Session,
  expected : @posoco.Session,
  raw : Json,
) -> Unit raise {
  assert_true(loaded.metadata == expected.metadata)
  assert_eq(loaded.messages.length(), expected.messages.length())
  match loaded.messages[0] {
    @posoco.Message::AssistantMessage(reasoning=Some(reasoning), ..) => {
      assert_eq(reasoning.content, "")
      // Parsed JSON equality includes version, roles, ids, statuses, opaque
      // encrypted strings and output item order, not object-key byte order.
      assert_true(reasoning.raw == Some(raw))
    }
    _ => fail("loaded compact anchor must retain its reasoning envelope")
  }
  assert_true(loaded.messages == expected.messages)
  // Canonical consumers must still see these, not just an empty anchor.
  assert_true(
    loaded.messages[1] ==
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text("Keep the first user request."),
    ]),
  )
  assert_true(
    loaded.messages[2] ==
    @posoco.Message::SystemMessage(content=[
      @posoco.Content::Text("profile coder activated\nUse the read tool."),
    ]),
  )
  match loaded.messages[4] {
    @posoco.Message::AssistantMessage(tool_calls~, finish_reason~, ..) => {
      assert_eq(tool_calls.length(), 1)
      assert_eq(tool_calls[0].call_id.to_string(), "call_fixture")
      assert_eq(tool_calls[0].name.to_string(), "read")
      assert_true(
        tool_calls[0].arguments ==
        @json.parse("{\"path\":\"src/main.mbt\",\"limit\":2}"),
      )
      assert_true(finish_reason == @posoco.FinishReason::ToolCalls)
    }
    _ => fail("loaded projection must retain the tool call")
  }
}

///|
test "compact_replay serde preserves opaque Object envelope and canonical projection" {
  let (raw, session) = compact_replay_fixture()
  let jsonl = session_to_jsonl(session)
  let loaded = match session_from_jsonl(jsonl) {
    Ok(loaded) => loaded
    Err(error) => fail("compact replay serde failed: \{error}")
  }
  assert_compact_replay_preserved(loaded, session, raw)
}

///|
async test "compact_replay store save and fresh load preserve envelope projection and appended turn" {
  let (raw, session) = compact_replay_fixture()
  let root = @fs.tmpdir(prefix="posoco-fs-session-compact-replay-")
  {
    defer @fs.rmdir(root, recursive=true)
    let writer = JsonlSessionStore(root)
    // Replace an existing committed transcript, as successful compact does.
    writer.save("compact_fixture", {
      messages: [
        @posoco.Message::UserMessage(content=[
          @posoco.Content::Text("old transcript to replace"),
        ]),
      ],
      metadata: Map::from_array([]),
    })
    writer.save("compact_fixture", session)
    let reader = JsonlSessionStore(root)
    let loaded = reader.load("compact_fixture")
    assert_compact_replay_preserved(loaded, session, raw)
    let appended = [
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text("Continue after compact."),
      ]),
    ]
    reader.append_messages(
      "compact_fixture",
      loaded.messages.length(),
      appended[:],
    )
    session.messages.push(appended[0])
    let resumed = JsonlSessionStore(root).load("compact_fixture")
    assert_compact_replay_preserved(resumed, session, raw)
  }
  assert_false(@fs.exists(root))
}
