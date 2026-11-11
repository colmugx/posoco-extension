///|
/// B0/B2: missing session, durable snapshot, atomic checkpoint metadata,
/// logical cursor, and truncate boundaries on a real embedded engine.
async test "hawdb session: load save checkpoint truncate" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(store) => store
    Err(e) => fail("open failed: \{e}")
  }
  let empty = store.load("missing") catch {
    e => fail("missing load failed: \{e}")
  }
  assert_eq(empty.messages.length(), 0)
  let session = @posoco.Session::{
    messages: [
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("你好 🌍")]),
    ],
    metadata: {"name": Json::string("original")},
  }
  store.save("first", session) catch {
    e => fail("save failed: \{e}")
  }
  let saved = store.load("first") catch {
    e => fail("load failed: \{e}")
  }
  assert_true(saved == session)
  store.checkpoint("first", {
    from_index: 999,
    messages: [
      @posoco.Message::AssistantMessage(
        content=[@posoco.Content::Text("done")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@posoco.FinishReason::Stop,
      ),
    ],
    metadata: Some({"name": Json::string("updated"), "counter": Json::number(7)}),
  }) catch {
    e => fail("checkpoint failed: \{e}")
  }
  let after = store.load("first") catch {
    e => fail("checkpoint load failed: \{e}")
  }
  assert_eq(after.messages.length(), 2)
  assert_true(after.metadata.get("name") == Some(Json::string("updated")))
  store.truncate("first", 1) catch {
    e => fail("truncate failed: \{e}")
  }
  let truncated = store.load("first") catch {
    e => fail("truncate load failed: \{e}")
  }
  assert_eq(truncated.messages.length(), 1)
  assert_true(truncated.metadata == after.metadata)
  store.truncate("first", -5) catch {
    e => fail("clamped truncate failed: \{e}")
  }
  let clamped = store.load("first") catch {
    e => fail("clamped load failed: \{e}")
  }
  assert_eq(clamped.messages.length(), 0)
  store.close()
}

///|
/// A failed codec read must be surfaced, not converted to an empty session.
async test "hawdb session: corrupt persisted JSON is Load error" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(store) => store
    Err(e) => fail("open failed: \{e}")
  }
  match store.db.query_sql(
    "INSERT INTO posoco_sessions (id, document) VALUES ($1, $2)",
    [@hawdb.Value::Text("bad"), @hawdb.Value::Text("{broken\n")],
  ) {
    Ok(_) => ()
    Err(e) => fail("fixture insert failed: \{e.describe()}")
  }
  try store.load("bad") catch {
    @posoco.SessionError::Load(_) => ()
    e => fail("expected Load error, got \{e}")
  } noraise {
    _ => fail("corrupt persisted JSON must not load")
  }
  store.close()
}

///|
/// A persisted HawDB session survives close/open, unlike in-memory smoke.
async test "hawdb session: persisted snapshot survives reopen" {
  let path = "./posoco-ext-hawdb-session-test-reopen"
  let store = match HawdbSessionStore::open(path) {
    Ok(store) => store
    Err(e) => fail("persistent open failed: \{e}")
  }
  let original = @posoco.Session::{
    messages: [
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("重启持久化 🚀")]),
    ],
    metadata: {"state": Json::string("durable")},
  }
  store.save("restart", original) catch {
    e => fail("persistent save failed: \{e}")
  }
  store.close()
  let reopened = match HawdbSessionStore::open(path) {
    Ok(store) => store
    Err(e) => fail("persistent reopen failed: \{e}")
  }
  let actual = reopened.load("restart") catch {
    e => fail("persistent load failed: \{e}")
  }
  assert_true(actual == original)
  reopened.close()
}

///|
/// A failed write transaction must not leave a partially updated session.
async test "hawdb session: rollback preserves committed document" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(store) => store
    Err(e) => fail("open failed: \{e}")
  }
  let before = @posoco.Session::{
    messages: [
      @posoco.Message::UserMessage(content=[@posoco.Content::Text("committed")]),
    ],
    metadata: {"revision": Json::number(1)},
  }
  store.save("rollback", before) catch {
    e => fail("seed save failed: \{e}")
  }
  let attempted : Result[Unit, @hawdb.HawdbError] = store.db.with_transaction(fn(tx) {
    let _ = tx.query_sql(
      "DELETE FROM posoco_sessions WHERE id = $1",
      [@hawdb.Value::Text("rollback")],
    )
    Err(@hawdb.HawdbError::Codec("injected rollback"))
  })
  match attempted {
    Err(@hawdb.HawdbError::Codec(_)) => ()
    _ => fail("rollback must preserve injected failure")
  }
  let after = store.load("rollback") catch {
    e => fail("load after rollback failed: \{e}")
  }
  assert_true(after == before)
  store.close()
}

///|
async test "hawdb session: incomplete snapshot cannot be silently recovered" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(store) => store
    Err(e) => fail("open failed: \{e}")
  }
  match store.db.query_sql(
    "INSERT INTO posoco_sessions (id, document) VALUES ($1, $2)",
    [
      @hawdb.Value::Text("truncated"),
      @hawdb.Value::Text("{}\n{\"role\":\"user\""),
    ],
  ) {
    Ok(_) => ()
    Err(e) => fail("fixture insert failed: \{e.describe()}")
  }
  try store.load("truncated") catch {
    @posoco.SessionError::Load(_) => ()
    e => fail("expected Load error, got \{e}")
  } noraise {
    _ => fail("truncated transaction snapshot must fail load")
  }
  store.close()
}
