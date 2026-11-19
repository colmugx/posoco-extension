///|
async test "hawdb: independent native session lifecycle" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let empty = store.load("missing") catch {
    error => fail("load empty: \{error}")
  }
  assert_true(empty.messages.is_empty())
  assert_true(empty.metadata.is_empty())

  let first = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("你好 🌍"),
    @posoco.Content::Image(media_type="image/png", data="aGVsbG8="),
  ])
  let second = @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text("answer")],
    tool_calls=[],
    reasoning=Some(@posoco.Reasoning::{
      content: "thinking",
      raw: Some(Json::object({"reasoning": Json::array([Json::string("raw")])})),
    }),
    finish_reason=@posoco.FinishReason::Other("stop"),
  )
  store.save("one", {
    messages: [first],
    metadata: {"name": Json::string("initial")},
  }) catch { error => fail("save: \{error}") }

  store.checkpoint("one", {
    from_index: 99,
    messages: [second],
    metadata: Some({"name": Json::string("updated")}),
  }) catch { error => fail("checkpoint: \{error}") }
  let actual = store.load("one") catch {
    error => fail("load: \{error}")
  }
  assert_eq(actual.messages.length(), 2)
  assert_true(actual.messages[0] == first)
  assert_true(actual.messages[1] == second)
  assert_true(actual.metadata.get("name") == Some(Json::string("updated")))

  store.truncate("one", 1) catch { error => fail("truncate: \{error}") }
  let shortened = store.load("one") catch {
    error => fail("load truncated: \{error}")
  }
  assert_eq(shortened.messages.length(), 1)
  assert_true(shortened.metadata.get("name") == Some(Json::string("updated")))
  store.truncate("one", -2) catch { error => fail("truncate negative: \{error}") }
  let erased = store.load("one") catch {
    error => fail("load erased: \{error}")
  }
  assert_true(erased.messages.is_empty())
  store.close()
}

///|
async test "hawdb: checkpoint inserts only new message rows" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let first = @posoco.Message::UserMessage(content=[@posoco.Content::Text("first")])
  let second = @posoco.Message::UserMessage(content=[@posoco.Content::Text("second")])
  let third = @posoco.Message::UserMessage(content=[@posoco.Content::Text("third")])
  store.save("incremental", { messages: [first], metadata: Map([]), }) catch {
    error => fail("save: \{error}")
  }
  store.checkpoint("incremental", {
    from_index: 100,
    messages: [second, third],
    metadata: None,
  }) catch { error => fail("append: \{error}") }
  let rows = match store.db.query_sql(
    "SELECT seq, document FROM posoco_hawdb_messages WHERE id = $1 ORDER BY seq",
    [@hawdb.Value::Text("incremental")],
  ) {
    Ok(value) => value
    Err(error) => fail("read rows: \{error.describe()}")
  }
  assert_eq(rows.rows.length(), 3)
  for i in 0..<rows.rows.length() {
    match rows.get(i, "seq") {
      Some(@hawdb.Value::Int(index)) => assert_true(index == i.to_int64())
      _ => fail("invalid sequence")
    }
  }
  let initial_record = match rows.get(0, "document") {
    Some(@hawdb.Value::Text(data)) => data
    _ => fail("missing first record")
  }
  assert_true(initial_record == hawdb_encode_message(first))
  let state = store.load("incremental") catch { error => fail("load: \{error}") }
  assert_eq(state.messages.length(), 3)
  assert_true(state.messages[1] == second)
  assert_true(state.messages[2] == third)
  store.save("incremental", {
    messages: [third],
    metadata: {"replaced": Json::boolean(true)},
  }) catch { error => fail("replace: \{error}") }
  let replaced = store.load("incremental") catch {
    error => fail("load replaced: \{error}")
  }
  assert_eq(replaced.messages.length(), 1)
  assert_true(replaced.messages[0] == third)
  store.close()
}

///|
async test "hawdb: typed tool outcomes round trip" {
  let variants : Array[@posoco.ToolOutcome] = [
    @posoco.ToolOutcome::Success(content="ok", structured=Some(Json::object({"k": Json::number(1)}))),
    @posoco.ToolOutcome::SuccessWithAttachments(
      content="attachment",
      structured=None,
      attachments=[@posoco.Content::Image(media_type="image/png", data="YQ==")],
    ),
    @posoco.ToolOutcome::ToolReportedError(content="denied", structured=Some(Json::string("payload"))),
    @posoco.ToolOutcome::RuntimeFailure(error_category="runtime", message="exception"),
    @posoco.ToolOutcome::NotExecuted(
      reason=@posoco.NotExecutedReason::SupersededByMessage,
      original_call_id=@posoco.CallId::unchecked("previous"),
    ),
  ]
  for outcome in variants {
    let message = @posoco.Message::ToolMessage(
      call_id=@posoco.CallId::unchecked("call"),
      tool_name=@posoco.ToolName::unchecked("tool"),
      outcome~,
    )
    let raw = hawdb_encode_message(message)
    let decoded = match hawdb_decode_message(raw) {
      Ok(value) => value
      Err(reason) => fail("decode: " + reason)
    }
    assert_true(decoded == message)
  }
}

///|
async test "hawdb: native corruption fails closed" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let message = @posoco.Message::UserMessage(content=[@posoco.Content::Text("keep")])
  store.save("bad", { messages: [message], metadata: Map([]), }) catch {
    error => fail("save: \{error}")
  }
  match store.db.query_sql(
    "UPDATE posoco_hawdb_messages SET document = $1 WHERE id = $2",
    [@hawdb.Value::Text("{broken"), @hawdb.Value::Text("bad")],
  ) {
    Ok(_) => ()
    Err(error) => fail("corrupt fixture: \{error.describe()}")
  }
  try store.load("bad") catch {
    @posoco.SessionError::Load(_) => ()
    error => fail("expected Load, got \{error}")
  } noraise {
    _ => fail("invalid JSON was accepted")
  }
  store.close()
}

///|
async test "hawdb: rollback does not publish partial session" {
  let store = match HawdbSessionStore::open_in_memory() {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let before = @posoco.Session::{
    messages: [@posoco.Message::UserMessage(content=[@posoco.Content::Text("before")])],
    metadata: {"state": Json::string("committed")},
  }
  store.save("rollback", before) catch { error => fail("save: \{error}") }
  let failed : Result[Unit, @hawdb.HawdbError] = store.db.with_transaction(fn(tx) {
    let _ = tx.query_sql(
      "DELETE FROM posoco_hawdb_messages WHERE id = $1",
      [@hawdb.Value::Text("rollback")],
    )
    Err(@hawdb.HawdbError::Codec("rollback"))
  })
  match failed {
    Err(@hawdb.HawdbError::Codec(_)) => ()
    _ => fail("transaction unexpectedly committed")
  }
  let after = store.load("rollback") catch { error => fail("load: \{error}") }
  assert_true(after == before)
  store.close()
}

///|
async test "hawdb: persisted session survives reopen" {
  let path = "./posoco-hawdb-independent-reopen"
  let store = match HawdbSessionStore::open(path) {
    Ok(value) => value
    Err(error) => fail("open: " + error)
  }
  let original = @posoco.Session::{
    messages: [@posoco.Message::UserMessage(content=[@posoco.Content::Text("durable")])],
    metadata: {"name": Json::string("reopen")},
  }
  store.save("durable", original) catch { error => fail("save: \{error}") }
  store.close()
  let reopened = match HawdbSessionStore::open(path) {
    Ok(value) => value
    Err(error) => fail("reopen: " + error)
  }
  let actual = reopened.load("durable") catch {
    error => fail("load reopened: \{error}")
  }
  assert_true(actual == original)
  reopened.close()
}
