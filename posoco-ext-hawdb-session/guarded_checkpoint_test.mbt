///|
async test "hawdb: guarded checkpoint rejects stale revisions" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  assert_true(store.revision("guard") == 0L)
  let first = @posoco.Message::UserMessage(content=[@posoco.Content::Text("first")])
  let second = @posoco.Message::UserMessage(content=[@posoco.Content::Text("second")])
  let committed = store.checkpoint_guarded("guard", 0L, "op-1", {
    from_index: 90,
    messages: [first],
    metadata: Some({"name": Json::string("one")}),
  }) catch { error => fail("initial guarded checkpoint: \{error}") }
  assert_true(committed == 1L)
  assert_true(store.revision("guard") == 1L)

  try store.checkpoint_guarded("guard", 0L, "op-2", {
    from_index: 0,
    messages: [second],
    metadata: None,
  }) catch {
    @posoco.SessionError::Save(_) => ()
    error => fail("expected stale revision error, got \{error}")
  } noraise {
    _ => fail("stale revision accepted")
  }
  let after = store.load("guard") catch {
    error => fail("load: \{error}")
  }
  assert_eq(after.messages.length(), 1)
  assert_true(after.messages[0] == first)
  assert_true(after.metadata.get("name") == Some(Json::string("one")))
  store.close()
}

///|
async test "hawdb: guarded checkpoint retries are idempotent" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let first = @posoco.Message::UserMessage(content=[@posoco.Content::Text("initial")])
  let checkpoint : @posoco.SessionCheckpoint = {
    from_index: 4,
    messages: [first],
    metadata: Some({"flag": Json::boolean(true)}),
  }
  let committed = store.checkpoint_guarded("retry", 0L, "request-a", checkpoint) catch {
    error => fail("checkpoint: \{error}")
  }
  assert_true(committed == 1L)
  let retried = store.checkpoint_guarded("retry", 0L, "request-a", checkpoint) catch {
    error => fail("retry: \{error}")
  }
  assert_true(retried == 1L)
  assert_true(store.revision("retry") == 1L)
  let state = store.load("retry") catch { error => fail("load: \{error}") }
  assert_eq(state.messages.length(), 1)
  assert_true(state.messages[0] == first)

  let altered : @posoco.SessionCheckpoint = {
    from_index: 4,
    messages: [@posoco.Message::UserMessage(content=[@posoco.Content::Text("modified")])],
    metadata: Some({"flag": Json::boolean(true)}),
  }
  try store.checkpoint_guarded("retry", 0L, "request-a", altered) catch {
    @posoco.SessionError::Save(_) => ()
    error => fail("expected operation conflict, got \{error}")
  } noraise {
    _ => fail("same request id with different payload accepted")
  }
  assert_true(store.revision("retry") == 1L)
  store.close()
}

///|
async test "hawdb: revisions increase after save, truncate and append" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let first = @posoco.Message::UserMessage(content=[@posoco.Content::Text("one")])
  let second = @posoco.Message::UserMessage(content=[@posoco.Content::Text("two")])
  store.save("revision", { messages: [first], metadata: Map([]), }) catch {
    error => fail("save: \{error}")
  }
  assert_true(store.revision("revision") == 1L)
  store.append_messages("revision", 1, [second][:]) catch {
    error => fail("append: \{error}")
  }
  assert_true(store.revision("revision") == 2L)
  store.truncate("revision", 1) catch {
    error => fail("truncate: \{error}")
  }
  assert_true(store.revision("revision") == 3L)
  let next = store.checkpoint_guarded("revision", 3L, "op-new", {
    from_index: 1,
    messages: [second],
    metadata: None,
  }) catch { error => fail("guarded: \{error}") }
  assert_true(next == 4L)
  let result = store.load("revision") catch {
    error => fail("reload: \{error}")
  }
  assert_eq(result.messages.length(), 2)
  assert_true(result.messages[0] == first)
  assert_true(result.messages[1] == second)
  store.close()
}

///|
async test "hawdb: no-op guarded checkpoint can be retried" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let checkpoint : @posoco.SessionCheckpoint = {
    from_index: 0,
    messages: [],
    metadata: None,
  }
  let first = store.checkpoint_guarded("empty", 0L, "noop", checkpoint) catch {
    error => fail("first: \{error}")
  }
  let again = store.checkpoint_guarded("empty", 0L, "noop", checkpoint) catch {
    error => fail("retry: \{error}")
  }
  assert_true(first == 0L)
  assert_true(again == 0L)
  assert_true(store.revision("empty") == 0L)
  store.close()
}
