///|
/// JS-target IO tests for JsonlSessionStore (bun runtime).
///
/// `moon test --target js` runs under Node, where the store's Bun-based
/// externs (`Bun.file` / `Bun.write`) do not exist; the tests self-skip there
/// and execute only under a bun-driven run of the generated bundle, e.g.
/// `bun _build/js/debug/test/colmugx/posoco-ext-fs-session/*.blackbox_test.js
/// '{"file_and_index":[["jsonl_session_js_test.mbt",[{"start":0,"end":2}]]]}'`.

///|
extern "js" fn js_bun_available() -> Bool =
  #| () => typeof Bun !== "undefined"

///|
extern "js" fn js_now_ms() -> Int32 =
  #| () => Date.now()

///|
priv struct StatusCapture {
  events : Array[@kit_events.StatusOp]
}

///|
fn StatusCapture::StatusCapture() -> StatusCapture {
  { events: [], }
}

///|
/// One test's status channel: a fresh event system that captures the closed
/// `StatusChanged` operations plus the owner-bound capability the store
/// publishes through (the pair assembly mints per extension).
struct StatusChannel {
  store : @posoco.Events
}

///|
fn capture_status_system(capture : StatusCapture) -> StatusChannel {
  let system = @posoco.EventSystem()
  match
    system.subscribe(fn(envelope) {
      match @kit_events.status_changed_of(envelope) {
        Some(op) => capture.events.push(op)
        None => ()
      }
    }) {
    Ok(_) => ()
    Err(_) => abort("subscribe on a fresh EventSystem failed")
  }
  let store = match system.publisher(owner="posoco_ext_fs_session") {
    Ok(store) => store
    Err(_) => abort("publisher on a fresh EventSystem failed")
  }
  { store, }
}

///|
/// One test's selection channel: a fresh system, the capability ext-llm's
/// router publishes `ModelSelection` through, and the store's own capability.
struct SelectionChannel {
  publisher : @posoco.Events
  store : @posoco.Events
}

///|
fn selection_system() -> SelectionChannel {
  let system = @posoco.EventSystem()
  let publisher = match system.publisher(owner="posoco_ext_llm") {
    Ok(publisher) => publisher
    Err(_) => abort("publisher on a fresh EventSystem failed")
  }
  let store = match system.publisher(owner="posoco_ext_fs_session") {
    Ok(store) => store
    Err(_) => abort("publisher on a fresh EventSystem failed")
  }
  { publisher, store, }
}

///|
async test "io[js]: save and append publish the session status register" {
  if !js_bun_available() {
    return
  }
  let root = "/tmp/posoco-fs-session-js-status-" + js_now_ms().to_string()
  let capture = StatusCapture::StatusCapture()
  let channel = capture_status_system(capture)
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    events=channel.store,
  )
  let msgs : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hello")]),
  ]
  store.save("sess_s", @posoco.Session::{
    messages: [],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("save failed: \{e}")
  }
  store.append_messages("sess_a", 0, msgs[:]) catch {
    e => fail("append failed: \{e}")
  }
  assert_eq(capture.events.length(), 2)
  debug_inspect(
    capture.events[0],
    content=(
      #|Register(segment="session", label=None, priority=80, value=Some("sess_s"), color=None)
    ),
  )
  debug_inspect(
    capture.events[1],
    content=(
      #|Register(segment="session", label=None, priority=80, value=Some("sess_a"), color=None)
    ),
  )
}

///|
async test "io[js]: append_messages first write stores full jsonl" {
  if !js_bun_available() {
    return
  }
  let root = "/tmp/posoco-fs-session-js-first-" + js_now_ms().to_string()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  let msgs : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("hello")]),
    @posoco.Message::AssistantMessage(
      content=[@posoco.Content::Text("hi there")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
    ),
  ]
  store.append_messages("sess_1", 0, msgs[:]) catch {
    e => fail("first append should write full jsonl: \{e}")
  }
  let loaded = store.load("sess_1") catch {
    e => fail("load after first append failed: \{e}")
  }
  assert_eq(loaded.messages.length(), 2)
  match loaded.messages[0] {
    @posoco.Message::UserMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(t) => assert_eq(t, "hello")
        _ => fail("expected Text content")
      }
    _ => fail("expected UserMessage")
  }
}

///|
async test "io[js]: append_messages on existing file appends only new lines" {
  if !js_bun_available() {
    return
  }
  let root = "/tmp/posoco-fs-session-js-append-" + js_now_ms().to_string()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  let first : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("one")]),
  ]
  store.append_messages("sess_2", 0, first[:]) catch {
    e => fail("first append failed: \{e}")
  }
  let second : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("two")]),
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("three")]),
  ]
  store.append_messages("sess_2", 1, second[:]) catch {
    e => fail("second append failed: \{e}")
  }
  let loaded = store.load("sess_2") catch {
    e => fail("load after appends failed: \{e}")
  }
  assert_eq(loaded.messages.length(), 3)
  match loaded.messages[2] {
    @posoco.Message::UserMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(t) => assert_eq(t, "three")
        _ => fail("expected Text content")
      }
    _ => fail("expected UserMessage")
  }
}

///|
#module("node:fs")
extern "js" fn js_test_read_sync(path : String, encoding : String) -> String = "readFileSync"

///|
/// Publish one `ModelSelection` event the way ext-llm's router does.
fn js_publish_selection(
  publisher : @posoco.Events,
  slot~ : String,
  effort~ : String? = None,
) -> Unit {
  let payload : @kit_events.ModelSelectionPayload = { slot_id: slot, effort, }
  ignore(publisher.publish(@kit_events.ModelSelection(payload)))
}

///|
/// First physical line of a stored journal.
fn js_stored_metadata_line(path : String) -> String {
  js_test_read_sync(path, "utf8")
}

///|
async test "io[js]: observed selection decorates save, append, and summary" {
  if !js_bun_available() {
    return
  }
  let root = "/tmp/posoco-fs-session-js-sel-" + js_now_ms().to_string()
  let channel = selection_system()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    events=channel.store,
  )
  js_publish_selection(
    channel.publisher,
    slot="qwen/glm-4.6",
    effort=Some("high"),
  )
  let one : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("one")]),
  ]
  store.append_messages("sess_sel", 0, one[:]) catch {
    e => fail("first append failed: \{e}")
  }
  let s = store.summary("sess_sel") catch { e => fail("summary failed: \{e}") }
  assert_eq(s.model, Some("qwen/glm-4.6"))
  assert_eq(s.effort, Some("high"))
  // A later selection change is picked up by the next append's line-1
  // rewrite.
  js_publish_selection(channel.publisher, slot="z/d")
  let two : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("two")]),
  ]
  store.append_messages("sess_sel", 1, two[:]) catch {
    e => fail("second append failed: \{e}")
  }
  let s2 = store.summary("sess_sel") catch {
    e => fail("summary after rewrite failed: \{e}")
  }
  assert_eq(s2.model, Some("z/d"))
  assert_eq(s2.effort, None)
  let reloaded = store.load("sess_sel") catch {
    e => fail("reload failed: \{e}")
  }
  assert_eq(reloaded.messages.length(), 2)
}

///|
async test "io[js]: append without a change keeps the metadata line" {
  if !js_bun_available() {
    return
  }
  let root = "/tmp/posoco-fs-session-js-selfast-" + js_now_ms().to_string()
  let channel = selection_system()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(
    root,
    events=channel.store,
  )
  js_publish_selection(channel.publisher, slot="a/b")
  let one : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("one")]),
  ]
  store.append_messages("sess_fast", 0, one[:]) catch {
    e => fail("first append failed: \{e}")
  }
  let path = @posoco-ext-fs-session.jsonl_session_path(root, "sess_fast")
  let before = js_stored_metadata_line(path)
  let two : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("two")]),
  ]
  store.append_messages("sess_fast", 1, two[:]) catch {
    e => fail("second append failed: \{e}")
  }
  assert_eq(js_stored_metadata_line(path), before)
}

///|
async test "io[js]: v2 selection survives append metadata rewrite" {
  if !js_bun_available() {
    return
  }
  let root = "/tmp/posoco-fs-session-js-v2-" + js_now_ms().to_string()
  let store = @posoco-ext-fs-session.JsonlSessionStore::JsonlSessionStore(root)
  let first : @posoco-ext-fs-session.SessionSelectionV2 = {
    owner: "owned-manager",
    model_id: "opaque-one",
    effort: None,
    pending: false,
    revision: 1L,
  }
  store.observe_selection_v2(first)
  let one : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("one")]),
  ]
  store.append_messages("sess_v2", 0, one[:]) catch {
    e => fail("v2 first append failed: \{e}")
  }
  let second = { ..first, model_id: "opaque-two", revision: 2L, }
  store.observe_selection_v2(second)
  store.append_messages("sess_v2", 1, one[:]) catch {
    e => fail("v2 second append failed: \{e}")
  }
  let saved = store.load("sess_v2") catch { e => fail("v2 read failed: \{e}") }
  assert_eq(saved.messages.length(), 2)
  assert_eq(
    @posoco-ext-fs-session.session_selection_v2_from_metadata(saved.metadata),
    Some(second),
  )
}
