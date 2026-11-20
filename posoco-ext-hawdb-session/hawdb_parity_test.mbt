///|
async test "hawdb: extension contributes the SessionPort" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(reason) => fail("open: " + reason)
  }
  let ext : &@posoco.Extension = store
  assert_eq(ext.extension_id(), "posoco_ext_hawdb_session")
  assert_eq(ext.manifest().sessions.length(), 1)
  assert_true(ext.manifest().commands.is_empty())
  store.close()
}

///|
async test "hawdb: list, summary and rename preserve session data" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(reason) => fail("open: " + reason)
  }
  let missing = store.list_ids() catch {
    error => fail("list empty: \{error}")
  }
  assert_true(missing.is_empty())
  let alpha = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("first message"),
  ])
  store.save("b-session", {
    messages: [alpha],
    metadata: {
      @posoco.SESSION_TITLE_METADATA_KEY: Json::string("  Automatic  title "),
      "cetas.cwd": Json::string("/work/project"),
      "posoco.model_selection": Json::object({
        "slot_id": Json::string("openai/test"),
        "effort": Json::string("high"),
      }),
    },
  }) catch { error => fail("save b: \{error}") }
  store.save("a-session", {
    messages: [],
    metadata: Map([]),
  }) catch { error => fail("save a: \{error}") }
  let ids = store.list_ids() catch { error => fail("list: \{error}") }
  assert_eq(ids.length(), 2)
  assert_eq(ids[0], "a-session")
  assert_eq(ids[1], "b-session")

  let initial = store.summary("b-session") catch {
    error => fail("summary: \{error}")
  }
  assert_eq(hawdb_display_title(initial), "Automatic title")
  assert_true(initial.cwd == Some("/work/project"))
  assert_true(initial.model == Some("openai/test"))
  assert_true(initial.effort == Some("high"))

  store.set_session_name("b-session", "Explicit name") catch {
    error => fail("rename: \{error}")
  }
  let renamed = store.summary("b-session") catch {
    error => fail("renamed summary: \{error}")
  }
  assert_eq(hawdb_display_title(renamed), "Explicit name")
  let after = store.load("b-session") catch {
    error => fail("load after rename: \{error}")
  }
  assert_eq(after.messages.length(), 1)
  assert_true(after.messages[0] == alpha)
  assert_true(after.metadata.get("cetas.cwd") == Some(Json::string("/work/project")))
  assert_true(store.current_id == Some("b-session"))
  store.close()
}

///|
async test "hawdb: invalid session IDs are rejected at storage boundary" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(reason) => fail("open: " + reason)
  }
  for id in ["", ".", "..", "a/b", "a\\b"] {
    assert_true(HawdbSessionStore::check_id(id) is Err(_))
    try store.save(id, { messages: [], metadata: Map([]), }) catch {
      @posoco.SessionError::Save(_) => ()
      error => fail("expected Save for \{id}: \{error}")
    } noraise {
      _ => fail("invalid session ID accepted for save")
    }
    try store.load(id) catch {
      @posoco.SessionError::Load(_) => ()
      error => fail("expected Load for \{id}: \{error}")
    } noraise {
      _ => fail("invalid session ID accepted for load")
    }
  }
  store.close()
}

///|
async test "hawdb: renaming a missing session does not create it" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(reason) => fail("open: " + reason)
  }
  try store.set_session_name("missing", "name") catch {
    @posoco.SessionError::Save(_) => ()
    error => fail("expected Save: \{error}")
  } noraise {
    _ => fail("renamed nonexistent session")
  }
  let ids = store.list_ids() catch { error => fail("list: \{error}") }
  assert_true(ids.is_empty())
  store.close()
}
