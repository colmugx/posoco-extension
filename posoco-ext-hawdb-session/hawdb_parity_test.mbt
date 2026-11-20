///|
async test "hawdb: extension contributes the SessionPort" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(reason) => fail("open: " + reason)
  }
  let ext : &@posoco.Extension = store
  assert_eq(ext.extension_id(), "posoco_ext_hawdb_session")
  assert_eq(ext.manifest().sessions.length(), 1)
  assert_eq(ext.manifest().commands.length(), 1)
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
      "posoco.title": Json::string("  Automatic  title "),
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
async test "hawdb: naming creates an empty session" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(reason) => fail("open: " + reason)
  }
  store.set_session_name("new", "name") catch {
    error => fail("name: \{error}")
  }
  let ids = store.list_ids() catch { error => fail("list: \{error}") }
  assert_eq(ids.length(), 1)
  assert_eq(ids[0], "new")
  let session = store.load("new") catch {
    error => fail("load named session: \{error}")
  }
  assert_true(session.messages.is_empty())
  assert_true(session.metadata.get("name") == Some(Json::string("name")))
  store.close()
}

///|
async test "hawdb: name command edits active session metadata" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(reason) => fail("open: " + reason)
  }
  assert_eq(store.commands().length(), 1)
  let first = store.invoke("name", Json::string("before"))
  match first {
    @posoco.CommandOutcome::Failure(..) => ()
    _ => fail("name without active session succeeded")
  }
  store.save("command", { messages: [], metadata: Map([]), }) catch {
    error => fail("save: \{error}")
  }
  let result = store.invoke("name", Json::object({
    "value": Json::string("Renamed"),
  }))
  match result {
    @posoco.CommandOutcome::Success(..) => ()
    _ => fail("rename command did not succeed")
  }
  let summary = store.summary("command") catch {
    error => fail("summary: \{error}")
  }
  assert_eq(hawdb_display_title(summary), "Renamed")
  let invalid = store.invoke("name", Json::string("  "))
  match invalid {
    @posoco.CommandOutcome::Failure(..) => ()
    _ => fail("blank name accepted")
  }
  store.close()
}

///|
async test "hawdb: initial empty append creates a session" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let empty : Array[@posoco.Message] = []
  store.append_messages("initial", 0, empty[:]) catch {
    error => fail("append: \{error}")
  }
  let ids = store.list_ids() catch { error => fail("list: \{error}") }
  assert_eq(ids.length(), 1)
  assert_eq(ids[0], "initial")
  let session = store.load("initial") catch { error => fail("load: \{error}") }
  assert_true(session.messages.is_empty())
  store.close()
}

///|
async test "hawdb: truncate missing session creates an empty session" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  store.truncate("empty-after-truncate", 100) catch {
    error => fail("truncate: \{error}")
  }
  let ids = store.list_ids() catch { error => fail("list: \{error}") }
  assert_eq(ids.length(), 1)
  assert_eq(ids[0], "empty-after-truncate")
  assert_true(store.load("empty-after-truncate").messages.is_empty())
  store.close()
}

///|
async test "hawdb: project directory is recorded on first append and save" {
  let store = match HawdbSessionStore::open_in_memory(
    cwd=Some("/work/project/"),
  ) {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("message"),
  ])
  store.append_messages("new", 0, [message][:]) catch {
    error => fail("append: \{error}")
  }
  let first = store.load("new") catch { error => fail("load: \{error}") }
  assert_true(first.metadata.get("cetas.cwd") == Some(Json::string("/work/project")))
  store.save("saved", { messages: [], metadata: Map([]), }) catch {
    error => fail("save: \{error}")
  }
  let second = store.load("saved") catch { error => fail("load: \{error}") }
  assert_true(second.metadata.get("cetas.cwd") == Some(Json::string("/work/project")))
  store.set_session_name("named", "name") catch {
    error => fail("name: \{error}")
  }
  let third = store.load("named") catch { error => fail("load: \{error}") }
  assert_true(third.metadata.get("cetas.cwd") == Some(Json::string("/work/project")))
  store.close()
}
