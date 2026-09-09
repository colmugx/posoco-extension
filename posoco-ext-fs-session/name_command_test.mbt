///|
/// name_command_test.mbt — native tests for set_session_name and /name.

///|
async test "io[native]: set_session_name persists metadata name" {
  let root = fresh_root("name-set")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_n", @posoco.Session::{
    messages: [],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("seed failed: \{e}")
  }
  store.set_session_name("sess_n", "Refactor sprint") catch {
    e => fail("set_session_name failed: \{e}")
  }
  let loaded = store.load("sess_n") catch { e => fail("reload failed: \{e}") }
  match loaded.metadata.get("name") {
    Some(Json::String(v)) => assert_eq(v, "Refactor sprint")
    _ => fail("expected name metadata, got unexpected outcome")
  }
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: append_messages preserves a stored name" {
  let root = fresh_root("name-append")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_a", @posoco.Session::{
    messages: [],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("seed failed: \{e}")
  }
  store.set_session_name("sess_a", "Kept name") catch {
    e => fail("set_session_name failed: \{e}")
  }
  let msgs : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("later turn")]),
  ]
  store.append_messages("sess_a", 0, msgs[:]) catch {
    e => fail("append failed: \{e}")
  }
  let loaded = store.load("sess_a") catch { e => fail("reload failed: \{e}") }
  match loaded.metadata.get("name") {
    Some(Json::String(v)) => assert_eq(v, "Kept name")
    _ => fail("name should survive append, got unexpected outcome")
  }
  assert_eq(loaded.messages.length(), 1)
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: /name invoke renames the current session" {
  let root = fresh_root("name-invoke")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  // Nothing persisted yet: current_id is unset, so /name fails closed.
  match store.invoke("name", Json::string("too early")) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("no active session"))
    _ => fail("expected Failure before first persist, got unexpected outcome")
  }
  store.save("sess_i", @posoco.Session::{
    messages: [],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("seed failed: \{e}")
  }
  match store.invoke("name", Json::string("Renamed via slash")) {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("Renamed via slash"))
    _ => fail("expected Success, got unexpected outcome")
  }
  let loaded = store.load("sess_i") catch { e => fail("reload failed: \{e}") }
  match loaded.metadata.get("name") {
    Some(Json::String(v)) => assert_eq(v, "Renamed via slash")
    _ => fail("expected persisted name, got unexpected outcome")
  }
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
async test "io[native]: /name accepts the object value field and rejects junk" {
  let root = fresh_root("name-args")
  let store = JsonlSessionStore::JsonlSessionStore(root)
  store.save("sess_o", @posoco.Session::{
    messages: [],
    metadata: Map::from_array([]),
  }) catch {
    e => fail("seed failed: \{e}")
  }
  // Frontends may wrap the positional in a {value: ...} object.
  match
    store.invoke(
      "name",
      Json::object(Map::from_array([("value", Json::string("Object form"))])),
    ) {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("object args should succeed, got unexpected outcome")
  }
  // Missing / wrong-shaped argument fails with usage guidance.
  match store.invoke("name", Json::null()) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("usage"))
    _ => fail("null args should fail with usage, got unexpected outcome")
  }
  match store.invoke("name", Json::string("   ")) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("usage"))
    _ => fail("blank name should fail with usage, got unexpected outcome")
  }
  // Unknown command ids fail closed.
  match store.invoke("other", Json::null()) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("unknown command"))
    _ => fail("unknown id should fail, got unexpected outcome")
  }
  // None of the failed invocations may have touched the persisted name.
  let loaded = store.load("sess_o") catch { e => fail("reload failed: \{e}") }
  match loaded.metadata.get("name") {
    Some(Json::String(v)) => assert_eq(v, "Object form")
    _ => fail("expected the object-form rename, got unexpected outcome")
  }
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
test "fs-session manifest contributes one commands port" {
  let store = JsonlSessionStore::JsonlSessionStore("sessions")
  let manifest = store.manifest()
  assert_eq(manifest.commands.length(), 1)
  let defs = manifest.commands[0].commands()
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].id, "name")
  assert_eq(defs[0].ctype, @posoco.CommandType::Input)
  assert_eq(defs[0].params.length(), 1)
  assert_true(defs[0].params[0].positional)
  assert_eq(defs[0].params[0].ptype, @posoco.ParamType::Str)
}
