///|
/// memory_session_test.mbt — Whitebox tests for InMemorySessionStore
///

///|
/// ——— Test 1: Load non-existent ID returns empty session ———
test "load_non_existent_returns_empty_session" {
  let store = InMemorySessionStore::new()
  let result = store.load("unknown_id")
  match result {
    Ok(session) => {
      assert_eq(session.messages.length(), 0)
      assert_eq(session.metadata.keys().to_array().length(), 0)
    }
    Err(_) => fail("expected Ok for non-existent session")
  }
}

///|
/// ——— Test 2: Save + load returns saved session ———
test "save_and_load_returns_saved_session" {
  let store = InMemorySessionStore::new()
  let msg = @posoco.Message::{
    role: @posoco.Role::User,
    content: [@posoco.Content::Text("hello")],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
  let session = @posoco.Session::{
    messages: [msg],
    metadata: Map::from_array([]),
  }
  let save_result = store.save("session_1", session)
  match save_result {
    Ok(_) => ()
    Err(_) => fail("expected Ok on save")
  }
  let load_result = store.load("session_1")
  match load_result {
    Ok(s) => {
      assert_eq(s.messages.length(), 1)
      match s.messages[0] {
        { role: @posoco.Role::User, content, .. } => {
          assert_eq(content.length(), 1)
        }
        _ => fail("expected User role")
      }
    }
    Err(_) => fail("expected Ok on load")
  }
}

///|
/// ——— Test 3: session_ids lists all stored IDs ———
test "session_ids_lists_all_stored_ids" {
  let store = InMemorySessionStore::new()
  let empty_session = @posoco.Session::{
    messages: [],
    metadata: Map::from_array([]),
  }

  // Initially empty
  assert_eq(store.session_ids().length(), 0)

  // After saving one session
  ignore(store.save("session_a", empty_session))
  assert_eq(store.session_ids().length(), 1)
  assert_true(store.session_ids().contains("session_a"))

  // After saving another session
  ignore(store.save("session_b", empty_session))
  let ids = store.session_ids()
  assert_eq(ids.length(), 2)
  assert_true(ids.contains("session_a"))
  assert_true(ids.contains("session_b"))
}
