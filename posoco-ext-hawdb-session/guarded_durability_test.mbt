///|
async test "hawdb: committed guarded checkpoint survives database reopen" {
  let path = "./posoco-hawdb-guarded-durability"
  let store = match HawdbSessionStore::open(path) {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let initial = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("initial"),
  ])
  let appended = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("durable 世界")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Other("done"),
  )
  store.save("persisted", {
    messages: [initial],
    metadata: {"name": Json::string("before")},
  }) catch { error => fail("save: \{error}") }
  let baseline = store.revision("persisted")
  let operation_id = "reopen-op-\{baseline}"
  let checkpoint : @posoco.SessionCheckpoint = {
    from_index: 170,
    messages: [appended],
    metadata: Some({"name": Json::string("after")}),
  }
  let revision = store.checkpoint_guarded(
    "persisted", baseline, operation_id, checkpoint,
  ) catch { error => fail("checkpoint: \{error}") }
  assert_true(revision == baseline + 1L)
  store.close()

  let reopened = match HawdbSessionStore::open(path) {
    Ok(value) => value
    Err(error) => fail("reopen: " + error)
  }
  assert_true(reopened.revision("persisted") == revision)
  let state = reopened.load("persisted") catch {
    error => fail("load: \{error}")
  }
  assert_eq(state.messages.length(), 2)
  assert_true(state.messages[0] == initial)
  assert_true(state.messages[1] == appended)
  assert_true(state.metadata.get("name") == Some(Json::string("after")))

  let same = reopened.checkpoint_guarded(
    "persisted", baseline, operation_id, checkpoint,
  ) catch { error => fail("receipt retry: \{error}") }
  assert_true(same == revision)
  assert_true(reopened.revision("persisted") == revision)
  let once = reopened.load("persisted") catch {
    error => fail("load after retry: \{error}")
  }
  assert_eq(once.messages.length(), 2)
  try reopened.checkpoint_guarded("persisted", baseline, "stale-\{baseline}", {
    from_index: 1,
    messages: [initial],
    metadata: None,
  }) catch {
    @posoco.SessionError::Save(_) => ()
    error => fail("expected stale revision, got \{error}")
  } noraise {
    _ => fail("stale revision accepted")
  }
  reopened.close()
}

///|
async test "hawdb: guarded operation IDs are scoped per session" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let first = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("first"),
  ])
  let second = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("second"),
  ])
  let a = store.checkpoint_guarded("ab", 0L, "c", {
    from_index: 0,
    messages: [first],
    metadata: None,
  }) catch { error => fail("first session: \{error}") }
  let b = store.checkpoint_guarded("a", 0L, "bc", {
    from_index: 0,
    messages: [second],
    metadata: None,
  }) catch { error => fail("second session: \{error}") }
  assert_true(a == 1L)
  assert_true(b == 1L)
  let first_state = store.load("ab") catch {
    error => fail("load first: \{error}")
  }
  let second_state = store.load("a") catch {
    error => fail("load second: \{error}")
  }
  assert_eq(first_state.messages.length(), 1)
  assert_eq(second_state.messages.length(), 1)
  assert_true(first_state.messages[0] == first)
  assert_true(second_state.messages[0] == second)
  store.close()
}

///|
async test "hawdb: failed guarded append rolls back revision and receipt" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let previous = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("committed"),
  ])
  let next = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("new"),
  ])
  store.save("roll", {
    messages: [previous],
    metadata: {"name": Json::string("safe")},
  }) catch { error => fail("save: \{error}") }
  assert_true(store.revision("roll") == 1L)
  match store.db.query_sql(
    "INSERT INTO posoco_hawdb_messages (entry_key, id, seq, document) VALUES ($1, $2, $3, $4)",
    [
      @hawdb.Value::Text("4:roll:1"),
      @hawdb.Value::Text("fixture"),
      @hawdb.Value::Int(0L),
      @hawdb.Value::Text("injected-key-conflict"),
    ],
  ) {
    Ok(_) => ()
    Err(error) => fail("inject: \{error.describe()}")
  }
  let checkpoint : @posoco.SessionCheckpoint = {
    from_index: 200,
    messages: [next],
    metadata: Some({"name": Json::string("new")}),
  }
  try store.checkpoint_guarded("roll", 1L, "retry-after-error", checkpoint) catch {
    @posoco.SessionError::Save(_) => ()
    error => fail("expected checkpoint failure, got \{error}")
  } noraise {
    _ => fail("conflicting row did not abort checkpoint")
  }
  assert_true(store.revision("roll") == 1L)
  let unchanged = store.load("roll") catch {
    error => fail("load after rollback: \{error}")
  }
  assert_eq(unchanged.messages.length(), 1)
  assert_true(unchanged.messages[0] == previous)
  assert_true(unchanged.metadata.get("name") == Some(Json::string("safe")))
  let receipts = match store.db.query_sql(
    "SELECT entry_key FROM posoco_hawdb_operations WHERE id = $1",
    [@hawdb.Value::Text("roll")],
  ) {
    Ok(value) => value
    Err(error) => fail("read receipts: \{error.describe()}")
  }
  assert_true(receipts.rows.is_empty())

  match store.db.query_sql(
    "DELETE FROM posoco_hawdb_messages WHERE entry_key = $1",
    [@hawdb.Value::Text("4:roll:1")],
  ) {
    Ok(_) => ()
    Err(error) => fail("clear injection: \{error.describe()}")
  }
  let committed = store.checkpoint_guarded(
    "roll", 1L, "retry-after-error", checkpoint,
  ) catch { error => fail("retry after rollback: \{error}") }
  assert_true(committed == 2L)
  let recovered = store.load("roll") catch {
    error => fail("reload: \{error}")
  }
  assert_eq(recovered.messages.length(), 2)
  assert_true(recovered.messages[0] == previous)
  assert_true(recovered.messages[1] == next)
  assert_true(recovered.metadata.get("name") == Some(Json::string("new")))
  store.close()
}
