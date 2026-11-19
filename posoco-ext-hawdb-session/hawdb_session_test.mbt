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

///|
/// B3 append stores one row per new message; historical snapshot is untouched.
async test "hawdb B3: append-only checkpoints keep baseline unchanged" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(store) => store
    Err(reason) => fail("open: " + reason)
  }
  let first = @posoco.Message::UserMessage(content=[@posoco.Content::Text("first")])
  let second = @posoco.Message::UserMessage(content=[@posoco.Content::Text("second 世界")])
  let third = @posoco.Message::UserMessage(content=[@posoco.Content::Text("third")])
  store.save("delta", {
    messages: [first],
    metadata: {"name": Json::string("old")},
  }) catch { reason => fail("initial save: \{reason}") }
  store.checkpoint("delta", {
    from_index: 999,
    messages: [second, third],
    metadata: Some({"name": Json::string("new")}),
  }) catch { reason => fail("append: \{reason}") }

  let document = store.db.query_sql(
    "SELECT document FROM posoco_sessions WHERE id = $1",
    [@hawdb.Value::Text("delta")],
  )
  let base = match document {
    Ok(rows) => rows
    Err(reason) => fail("read legacy base: \{reason.describe()}")
  }
  match base.get(0, "document") {
    Some(@hawdb.Value::Text(jsonl)) => {
      let decoded = match @codec.session_from_jsonl(jsonl) {
        Ok(session) => session
        Err(reason) => fail("decode legacy base: \{reason}")
      }
      assert_eq(decoded.messages.length(), 1)
      assert_true(decoded.messages[0] == first)
      assert_true(decoded.metadata.get("name") == Some(Json::string("old")))
    }
    _ => fail("legacy base not available")
  }
  let journal = store.db.query_sql(
    "SELECT seq FROM posoco_session_delta_rows WHERE id = $1 ORDER BY seq",
    [@hawdb.Value::Text("delta")],
  )
  match journal {
    Ok(rows) => {
      assert_eq(rows.rows.length(), 2)
      match rows.get(0, "seq") {
        Some(@hawdb.Value::Int(seq)) => assert_true(seq == 0L)
        _ => fail("first sequence")
      }
      match rows.get(1, "seq") {
        Some(@hawdb.Value::Int(seq)) => assert_true(seq == 1L)
        _ => fail("second sequence")
      }
    }
    Err(reason) => fail("journal query: \{reason.describe()}")
  }
  let restored = store.load("delta") catch {
    reason => fail("rebuild: \{reason}")
  }
  assert_eq(restored.messages.length(), 3)
  assert_true(restored.messages[0] == first)
  assert_true(restored.messages[1] == second)
  assert_true(restored.messages[2] == third)
  assert_true(restored.metadata.get("name") == Some(Json::string("new")))

  store.truncate("delta", 2) catch { reason => fail("truncate journal: \{reason}") }
  let cut = store.load("delta") catch { reason => fail("reload cut: \{reason}") }
  assert_eq(cut.messages.length(), 2)
  assert_true(cut.metadata.get("name") == Some(Json::string("new")))
  store.checkpoint("delta", {
    from_index: 0,
    messages: [third],
    metadata: None,
  }) catch { reason => fail("append after truncate: \{reason}") }
  let again = store.load("delta") catch { reason => fail("reload appended: \{reason}") }
  assert_eq(again.messages.length(), 3)
  assert_true(again.messages[2] == third)
  store.close()
}

///|
/// Full save atomically clears prior append rows, including metadata overrides.
async test "hawdb B3: full save replaces journal without stale messages" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(store) => store
    Err(reason) => fail("open: " + reason)
  }
  let msg = @posoco.Message::UserMessage(content=[@posoco.Content::Text("old")])
  store.append_messages("reset", 0, [msg][:]) catch {
    reason => fail("append: \{reason}")
  }
  store.checkpoint("reset", {
    from_index: 4,
    messages: [],
    metadata: Some({"name": Json::string("before")}),
  }) catch { reason => fail("metadata: \{reason}") }
  store.save("reset", {
    messages: [],
    metadata: {"name": Json::string("after")},
  }) catch { reason => fail("reset: \{reason}") }
  let session = store.load("reset") catch { reason => fail("load: \{reason}") }
  assert_true(session.messages.is_empty())
  assert_true(session.metadata.get("name") == Some(Json::string("after")))
  let journal = store.db.query_sql(
    "SELECT entry_key FROM posoco_session_delta_rows WHERE id = $1",
    [@hawdb.Value::Text("reset")],
  )
  match journal {
    Ok(rows) => assert_true(rows.rows.is_empty())
    Err(reason) => fail("journal query: \{reason.describe()}")
  }
  store.close()
}

///|
/// No head/row mismatches can be mistaken for an empty session.
async test "hawdb B3: corruption fails closed" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(store) => store
    Err(reason) => fail("open: " + reason)
  }
  let msg = @posoco.Message::UserMessage(content=[@posoco.Content::Text("durable")])
  store.append_messages("corrupt-delta", 0, [msg][:]) catch {
    reason => fail("append: \{reason}")
  }
  match store.db.query_sql(
    "DELETE FROM posoco_session_delta_rows WHERE id = $1",
    [@hawdb.Value::Text("corrupt-delta")],
  ) {
    Ok(_) => ()
    Err(reason) => fail("corrupt fixture: \{reason.describe()}")
  }
  try store.load("corrupt-delta") catch {
    @posoco.SessionError::Load(_) => ()
    reason => fail("expected Load, got \{reason}")
  } noraise {
    _ => fail("missing journal row must fail load")
  }
  store.close()
}
