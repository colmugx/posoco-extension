///|
/// jsonl_session_test.mbt — Whitebox tests for JsonlSessionStore.
///
/// Two layers:
/// 1. Pure codec tests (session_to_jsonl / session_from_jsonl) — no IO, no async.
/// 2. Native IO tests (JsonlSessionStore load/save round-trip) — async tests
/// over the SessionStore implementation, using tmpdir.
///
/// Codec tests are the contract surface for both targets; the JS target's
/// JS-side async adapter reuses the same codec, so target-specific filesystem
/// behaviour is isolated from codec regressions.

// Pure codec tests (no async, no IO)

///|
test "serde: empty session round-trips" {
  let session = @posoco.Session::{ messages: [], metadata: Map::from_array([]) }
  let jsonl = session_to_jsonl(session)
  // Empty session = just the metadata line + newline.
  assert_eq(jsonl, "{}\n")
  match session_from_jsonl(jsonl) {
    Ok(s) => {
      assert_eq(s.messages.length(), 0)
      assert_eq(s.metadata.keys().to_array().length(), 0)
    }
    Err(e) => fail("empty round-trip failed: \{e}")
  }
}

///|
test "serde: empty input returns empty session" {
  match session_from_jsonl("") {
    Ok(s) => {
      assert_eq(s.messages.length(), 0)
      assert_eq(s.metadata.keys().to_array().length(), 0)
    }
    Err(_) => fail("empty input should parse to empty session")
  }
  match session_from_jsonl("   \n  \n") {
    Ok(s) => assert_eq(s.messages.length(), 0)
    Err(_) => fail("whitespace-only input should parse to empty session")
  }
}

///|
test "serde: single user message round-trips" {
  let msg = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("hello"),
  ])
  let session = @posoco.Session::{
    messages: [msg],
    metadata: Map::from_array([]),
  }
  let jsonl = session_to_jsonl(session)
  // Sanity: contains the text body.
  assert_true(jsonl.contains("hello"))
  assert_true(jsonl.contains("\"role\":\"user\""))
  match session_from_jsonl(jsonl) {
    Ok(s) => {
      assert_eq(s.messages.length(), 1)
      match s.messages[0] {
        @posoco.Message::UserMessage(content~) => {
          assert_eq(content.length(), 1)
          match content[0] {
            @posoco.Content::Text(t) => assert_eq(t, "hello")
            _ => fail("expected Text content")
          }
        }
        _ => fail("expected UserMessage")
      }
    }
    Err(e) => fail("single message round-trip failed: \{e}")
  }
}

///|
test "serde: assistant message with tool_calls round-trips" {
  let tool_call = @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_1"),
    name: @posoco.ToolName::unchecked("bash"),
    arguments: Json::object(Map::from_array([("cmd", Json::string("ls"))])),
  }
  let msg = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("Running ls")],
    tool_calls=[tool_call],
    reasoning=Some(@posoco.Reasoning::{
      content: "thinking about ls",
      raw: None,
    }),
    finish_reason=@posoco.FinishReason::ToolCalls,
  )
  let session = @posoco.Session::{
    messages: [msg],
    metadata: Map::from_array([]),
  }
  match session_from_jsonl(session_to_jsonl(session)) {
    Ok(s) => {
      assert_eq(s.messages.length(), 1)
      match s.messages[0] {
        @posoco.Message::AssistantMessage(tool_calls~, reasoning~, ..) => {
          assert_eq(tool_calls.length(), 1)
          match tool_calls[0] {
            { call_id, name, .. } => {
              assert_eq(call_id.to_string(), "call_1")
              assert_eq(name.to_string(), "bash")
            }
          }
          match reasoning {
            Some(r) => assert_eq(r.content, "thinking about ls")
            None => fail("reasoning should round-trip")
          }
        }
        _ => fail("expected AssistantMessage")
      }
    }
    Err(e) => fail("tool_call round-trip failed: \{e}")
  }
}

///|
test "serde: reasoning raw payload round-trips" {
  let raw_items = Json::array([
    Json::object(
      Map::from_array([
        ("id", Json::string("rs_123")),
        ("type", Json::string("reasoning")),
        ("summary", Json::array([])),
      ]),
    ),
  ])
  let msg = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{
      content: "summary text",
      raw: Some(raw_items),
    }),
    finish_reason=@posoco.FinishReason::Stop,
  )
  let session = @posoco.Session::{
    messages: [msg],
    metadata: Map::from_array([]),
  }
  match session_from_jsonl(session_to_jsonl(session)) {
    Ok(s) =>
      match s.messages[0] {
        @posoco.Message::AssistantMessage(reasoning~, ..) =>
          match reasoning {
            Some(r) => {
              assert_eq(r.content, "summary text")
              assert_true(r.raw == Some(raw_items))
            }
            None => fail("reasoning should round-trip")
          }
        _ => fail("expected AssistantMessage")
      }
    Err(e) => fail("reasoning raw round-trip failed: \{e}")
  }
}

///|
test "serde: tool message with tool_call_id round-trips" {
  let msg = @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked("call_1"),
    tool_name=@posoco.ToolName::unchecked("read"),
    outcome=@posoco.ToolOutcome::Success(content="file.txt", structured=None),
  )
  let session = @posoco.Session::{
    messages: [msg],
    metadata: Map::from_array([]),
  }
  match session_from_jsonl(session_to_jsonl(session)) {
    Ok(s) =>
      match s.messages[0] {
        @posoco.Message::ToolMessage(call_id~, ..) =>
          assert_eq(call_id.to_string(), "call_1")
        _ => fail("expected ToolMessage with call_id")
      }
    Err(e) => fail("tool msg round-trip failed: \{e}")
  }
}

///|
test "serde: image content round-trips" {
  let msg = @posoco.Message::UserMessage(content=[
    @posoco.Content::Image(media_type="image/png", data="data:..."),
  ])
  let session = @posoco.Session::{
    messages: [msg],
    metadata: Map::from_array([]),
  }
  match session_from_jsonl(session_to_jsonl(session)) {
    Ok(s) =>
      match s.messages[0] {
        @posoco.Message::UserMessage(content~) =>
          match content[0] {
            @posoco.Content::Image(media_type~, data~) => {
              assert_eq(data, "data:...")
              assert_eq(media_type, "image/png")
            }
            _ => fail("expected Image content")
          }
        _ => fail("expected UserMessage")
      }
    Err(e) => fail("image round-trip failed: \{e}")
  }
}

///|
test "serde: metadata preserved" {
  let metadata = Map::from_array([
    ("parent_session_id", Json::string("sess_parent")),
    ("turn_count", Json::number(3.0)),
  ])
  let session = @posoco.Session::{ messages: [], metadata }
  match session_from_jsonl(session_to_jsonl(session)) {
    Ok(s) => {
      assert_true(s.metadata.contains("parent_session_id"))
      match s.metadata["parent_session_id"] {
        Json::String(v) => assert_eq(v, "sess_parent")
        _ => fail("parent_session_id should be string")
      }
      assert_true(s.metadata.contains("turn_count"))
      match s.metadata["turn_count"] {
        Json::Number(n, ..) => assert_eq(n, 3.0)
        _ => fail("turn_count should be number")
      }
    }
    Err(e) => fail("metadata round-trip failed: \{e}")
  }
}

///|
test "serde: malformed metadata line errors loudly" {
  // First non-empty line is not a JSON object.
  match session_from_jsonl("not json\n{}\n") {
    Err(@posoco.SessionError::Load(msg)) =>
      assert_true(msg.contains("metadata"))
    _ => fail("expected Load error for malformed metadata")
  }
}

///|
test "serde: malformed message line errors loudly" {
  // Valid metadata line, but second line is not valid JSON.
  match session_from_jsonl("{}\n{ not valid json }\n") {
    Err(@posoco.SessionError::Load(_)) => ()
    _ => fail("expected Load error for malformed message line")
  }
}

// Native IO tests (async, use @fs.tmpdir for unique scratch dirs)

///|
/// Create a unique scratch directory with the given prefix, returning its path.
/// Each call produces a fresh dir via `@fs.tmpdir`.
async fn fresh_root(prefix : String) -> String {
  @fs.tmpdir(prefix="posoco-fs-session-" + prefix + "-")
}

///|
async test "io[native]: load non-existent session returns empty" {
  let root = fresh_root("load-missing")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  let s = store.load("does_not_exist") catch {
    e => fail("missing session should Ok empty: \{e}")
  }
  assert_eq(s.messages.length(), 0)
  assert_eq(s.metadata.keys().to_array().length(), 0)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: save then load round-trips a full session" {
  let root = fresh_root("roundtrip")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  let session = @posoco.Session::{
    messages: [
      @posoco.Message::SystemMessage(content=[
        @posoco.Content::Text("be helpful"),
      ]),
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("hello")]),
      @posoco.Message::AssistantMessage(
        content=[@posoco.Content::Text("hi there")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@posoco.FinishReason::Stop,
      ),
    ],
    metadata: Map::from_array([("k", Json::string("v"))]),
  }
  store.save("sess_1", session) catch {
    e => fail("save failed: \{e}")
  }
  let loaded = store.load("sess_1") catch {
    e => fail("load after save failed: \{e}")
  }
  assert_eq(loaded.messages.length(), 3)
  assert_true(loaded.metadata.contains("k"))
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: save creates parent directory lazily" {
  // tmpdir() always creates the dir, so for lazy-mkdir we delete first then
  // save into the (now-missing) path; the impl should re-create it.
  let root = fresh_root("lazy-mkdir")
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
  let store = JsonlSessionStore::JsonlSessionStore(root)
  let session = @posoco.Session::{ messages: [], metadata: Map::from_array([]) }
  store.save("s", session) catch {
    e => fail("save should lazily create root: \{e}")
  }
  assert_true(@fs.exists(root))
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: overwrite existing session truncates correctly" {
  let root = fresh_root("overwrite")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  let big = @posoco.Session::{
    messages: [
      @posoco.Message::UserMessage(content=[
        @posoco.Content::Text("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
      ]),
    ],
    metadata: Map::from_array([]),
  }
  let small = @posoco.Session::{ messages: [], metadata: Map::from_array([]) }
  store.save("s", big) catch {
    _ => ()
  }
  store.save("s", small) catch {
    _ => ()
  }
  let s = store.load("s") catch {
    e => fail("load after overwrite failed: \{e}")
  }
  assert_eq(s.messages.length(), 0)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}
