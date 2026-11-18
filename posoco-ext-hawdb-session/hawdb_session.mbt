///|
/// Native HawDB-backed SessionStore (Stage B0/B2 correctness baseline).
/// This implementation uses a single transactional snapshot row per session.
/// B3 will replace full-document rewrites with ordered per-message storage.
/// Only a caller-owned instance (not shared across threads) is supported.
pub(all) struct HawdbSessionStore {
  db : @hawdb.Database
}

///|
/// The upstream engine deliberately rejects IF NOT EXISTS for content-store
/// tables because that would silently accept schema drift. Inspect first,
/// create only when absent, and verify the full table contract on every open.
fn ensure_session_schema(db : @hawdb.Database) -> Result[Unit, String] {
  let existing = match db.query_sql(
    "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'posoco_sessions'",
    [],
  ) {
    Ok(rows) => rows
    Err(error) => return Err(error.describe())
  }
  if existing.rows.length() == 0 {
    match db.query_sql(
      "CREATE TABLE posoco_sessions (id TEXT PRIMARY KEY, document TEXT)",
      [],
    ) {
      Ok(_) => ()
      Err(error) => return Err(error.describe())
    }
  } else if existing.rows.length() != 1 ||
    existing.get(0, "table_type") != Some(@hawdb.Value::Text("BASE TABLE")) {
    return Err("posoco_sessions must be a single ordinary table")
  }

  let columns = match db.query_sql(
    "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'posoco_sessions' ORDER BY ordinal_position",
    [],
  ) {
    Ok(rows) => rows
    Err(error) => return Err(error.describe())
  }
  if columns.rows.length() != 2 ||
    columns.get(0, "column_name") != Some(@hawdb.Value::Text("id")) ||
    columns.get(0, "data_type") != Some(@hawdb.Value::Text("text")) ||
    columns.get(0, "is_nullable") != Some(@hawdb.Value::Text("NO")) ||
    columns.get(1, "column_name") != Some(@hawdb.Value::Text("document")) ||
    columns.get(1, "data_type") != Some(@hawdb.Value::Text("text")) {
    return Err("posoco_sessions schema drift: expected id TEXT PRIMARY KEY, document TEXT")
  }

  let indexes = match db.query_sql(
    "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'posoco_sessions'",
    [],
  ) {
    Ok(rows) => rows
    Err(error) => return Err(error.describe())
  }
  if indexes.rows.length() != 1 ||
    indexes.get(0, "indexname") != Some(@hawdb.Value::Text("posoco_sessions_pkey")) {
    return Err("posoco_sessions schema drift: expected id PRIMARY KEY")
  }
  Ok(())
}

///|
fn finish_session_open(db : @hawdb.Database) -> Result[HawdbSessionStore, String] {
  match ensure_session_schema(db) {
    Ok(_) => Ok({ db, })
    Err(reason) => {
      db.close()
      Err(reason)
    }
  }
}

///|
pub fn HawdbSessionStore::open(path : String) -> Result[HawdbSessionStore, String] {
  match @hawdb.open(path) {
    Ok(db) => finish_session_open(db)
    Err(error) => Err(error.describe())
  }
}

///|
pub fn HawdbSessionStore::open_in_memory() -> Result[HawdbSessionStore, String] {
  match @hawdb.open_in_memory() {
    Ok(db) => finish_session_open(db)
    Err(error) => Err(error.describe())
  }
}

///|
pub fn HawdbSessionStore::close(self : HawdbSessionStore) -> Unit {
  self.db.close()
}

///|
fn empty_session() -> @posoco.Session {
  { messages: [], metadata: Map([]), }
}

///|
fn decode_document(document : String) -> Result[@posoco.Session, String] {
  // A HawDB row is transactionally materialized: there is no filesystem
  // torn-tail exception. Reject an incomplete snapshot rather than silently
  // replaying only the last valid message.
  if document == "" || !document.has_suffix("\n") {
    return Err("incomplete HawDB session snapshot")
  }
  match @codec.session_from_jsonl(document) {
    Ok(session) => Ok(session)
    Err(error) => Err(error.to_string())
  }
}

///|
fn transaction_load(
  tx : @hawdb.Transaction,
  id : String,
) -> Result[@posoco.Session, String] {
  let rows = match tx.query_sql(
    "SELECT document FROM posoco_sessions WHERE id = $1",
    [@hawdb.Value::Text(id)],
  ) {
    Ok(rows) => rows
    Err(error) => return Err(error.describe())
  }
  match rows.get(0, "document") {
    None => Ok(empty_session())
    Some(@hawdb.Value::Text(document)) => decode_document(document)
    _ => Err("session document column is not TEXT")
  }
}

///|
fn transaction_write(
  tx : @hawdb.Transaction,
  id : String,
  session : @posoco.Session,
) -> Result[Unit, String] {
  let encoded = @codec.session_to_jsonl(session)
  match tx.query_sql(
    "DELETE FROM posoco_sessions WHERE id = $1",
    [@hawdb.Value::Text(id)],
  ) {
    Err(error) => return Err(error.describe())
    Ok(_) => ()
  }
  match tx.query_sql(
    "INSERT INTO posoco_sessions (id, document) VALUES ($1, $2)",
    [@hawdb.Value::Text(id), @hawdb.Value::Text(encoded)],
  ) {
    Err(error) => Err(error.describe())
    Ok(_) => Ok(())
  }
}

///|
pub extend HawdbSessionStore with @posoco.SessionPort::{
  load,
  save,
  append_messages,
  checkpoint,
  truncate,
}

///|
pub impl @posoco.SessionPort for HawdbSessionStore with fn load(
  self,
  id : String,
) -> @posoco.Session raise @posoco.SessionError {
  let rows = match self.db.query_sql(
    "SELECT document FROM posoco_sessions WHERE id = $1",
    [@hawdb.Value::Text(id)],
  ) {
    Ok(rows) => rows
    Err(error) => raise @posoco.SessionError::Load(error.describe())
  }
  match rows.get(0, "document") {
    None => empty_session()
    Some(@hawdb.Value::Text(document)) =>
      match decode_document(document) {
        Ok(session) => session
        Err(reason) => raise @posoco.SessionError::Load(reason)
      }
    _ => raise @posoco.SessionError::Load("session document column is not TEXT")
  }
}

///|
pub impl @posoco.SessionPort for HawdbSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  let result = self.db.with_transaction(fn(tx) {
    match transaction_write(tx, id, session) {
      Ok(_) => Ok(())
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(_) => ()
    Err(error) => raise @posoco.SessionError::Save(error.describe())
  }
}

///|
/// Logical from_index is intentionally not equated with physical row count:
/// replay fixation can insert non-persisted transient messages. The snapshot
/// and metadata replacement are committed in the same HawDB transaction.
pub impl @posoco.SessionPort for HawdbSessionStore with fn checkpoint(
  self,
  id : String,
  checkpoint : @posoco.SessionCheckpoint,
) -> Unit raise @posoco.SessionError {
  let result = self.db.with_transaction(fn(tx) {
    let before = match transaction_load(tx, id) {
      Ok(session) => session
      Err(reason) => return Err(@hawdb.HawdbError::Codec(reason))
    }
    let tail = before.messages.copy()
    for msg in checkpoint.messages {
      tail.push(msg)
    }
    let metadata = match checkpoint.metadata {
      None => before.metadata
      Some(metadata) => metadata
    }
    match transaction_write(tx, id, { messages: tail, metadata, }) {
      Ok(_) => Ok(())
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(_) => ()
    Err(error) => raise @posoco.SessionError::Save(error.describe())
  }
}

///|
pub impl @posoco.SessionPort for HawdbSessionStore with fn append_messages(
  self,
  id : String,
  from_index : Int32,
  messages : ArrayView[@posoco.Message],
) -> Unit raise @posoco.SessionError {
  self.checkpoint(id, {
    from_index,
    messages: messages.to_owned(),
    metadata: None,
  })
}

///|
pub impl @posoco.SessionPort for HawdbSessionStore with fn truncate(
  self,
  id : String,
  from_index : Int32,
) -> Unit raise @posoco.SessionError {
  let result = self.db.with_transaction(fn(tx) {
    let before = match transaction_load(tx, id) {
      Ok(session) => session
      Err(reason) => return Err(@hawdb.HawdbError::Codec(reason))
    }
    let len = before.messages.length()
    let keep = if from_index < 0 {
      0
    } else if from_index > len {
      len
    } else {
      from_index
    }
    let next : Array[@posoco.Message] = []
    for i in 0..<keep {
      next.push(before.messages[i])
    }
    match transaction_write(tx, id, {
      messages: next,
      metadata: before.metadata,
    }) {
      Ok(_) => Ok(())
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(_) => ()
    Err(error) => raise @posoco.SessionError::Save(error.describe())
  }
}
