///|
/// JS-target IO tests for JsonlSessionStore (bun runtime). Native coverage
/// lives in jsonl_session_test.mbt; these mirror the append semantics that
/// only exist on the js implementation path.
///
/// `moon test --target js` runs under Node, where the store's Bun-based
/// externs (`Bun.file` / `Bun.write`) do not exist; the tests self-skip there
/// and execute only under a bun-driven run of the generated bundle, e.g.
/// `bun _build/js/debug/test/colmugx/posoco-ext-fs-session/*.blackbox_test.js
/// '{"file_and_index":[["jsonl_session_js_test.mbt",[{"start":0,"end":2}]]]}'`.

///|
/// `typeof Bun !== "undefined"` — true only on the bun runtime.
extern "js" fn js_bun_available() -> Bool =
  #| () => typeof Bun !== "undefined"

///|
/// `Date.now()` — unique-enough scratch-dir suffix.
extern "js" fn js_now_ms() -> Int =
  #| () => Date.now()

///|
priv struct StatusCapture {
  events : Array[@devkit.BusEvent]
}

///|
fn StatusCapture::StatusCapture() -> StatusCapture {
  { events: [], }
}

///|
impl @devkit.BusSubscriber for StatusCapture with fn on_bus_event(
  self : StatusCapture,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
async test "io[js]: save and append publish the session status register" {
  if !js_bun_available() {
    return
  }
  let root = "/tmp/posoco-fs-session-js-status-" + js_now_ms().to_string()
  let bus = @devkit.EventBus()
  let capture = StatusCapture::StatusCapture()
  bus.subscribe(capture)
  let store = JsonlSessionStore::JsonlSessionStore(root, bus=Some(bus))
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
  assert_eq(capture.events[0].source, "posoco_ext_fs_session")
  debug_inspect(
    @devkit.decode_status_op(capture.events[0]),
    content=(
      #|Some(Register(segment="session", label=None, priority=80, value=Some("sess_s")))
    ),
  )
  debug_inspect(
    @devkit.decode_status_op(capture.events[1]),
    content=(
      #|Some(Register(segment="session", label=None, priority=80, value=Some("sess_a")))
    ),
  )
}

///|
async test "io[js]: append_messages first write stores full jsonl" {
  if !js_bun_available() {
    return
  }
  let root = "/tmp/posoco-fs-session-js-first-" + js_now_ms().to_string()
  let store = JsonlSessionStore::JsonlSessionStore(root)
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
  let store = JsonlSessionStore::JsonlSessionStore(root)
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
