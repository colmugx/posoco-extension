///|
/// Native HawDB-backed SessionPort: B2 snapshot compatibility with a B3
/// transactional message delta journal. The archive is not shared across
/// MoonBit threads; multi-writer qualification is a separate production gate.
pub(all) struct HawdbSessionStore {
  db : @hawdb.Database
}

///|
/// HawDB Value is intentionally not Eq (it contains non-comparable values).
/// Match the text variant before comparing schema catalog fields.
fn catalog_text_is(value : @hawdb.Value?, expected : String) -> Bool {
  match value {
    Some(@hawdb.Value::Text(actual)) => actual == expected
    _ => false
  }
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
    !catalog_text_is(existing.get(0, "table_type"), "BASE TABLE") {
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
    !catalog_text_is(columns.get(0, "column_name"), "id") ||
    !catalog_text_is(columns.get(0, "data_type"), "text") ||
    !catalog_text_is(columns.get(0, "is_nullable"), "NO") ||
    !catalog_text_is(columns.get(1, "column_name"), "document") ||
    !catalog_text_is(columns.get(1, "data_type"), "text") {
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
    !catalog_text_is(indexes.get(0, "indexname"), "posoco_sessions_pkey") {
    return Err("posoco_sessions schema drift: expected id PRIMARY KEY")
  }
  Ok(())
}

///|
fn finish_session_open(db : @hawdb.Database) -> Result[HawdbSessionStore, String] {
  let result = match ensure_session_schema(db) {
    Ok(_) => ensure_delta_schema(db)
    Err(reason) => Err(reason)
  }
  match result {
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
  let result = self.db.with_read_transaction(fn(tx) {
    match transaction_load_complete(tx, id) {
      Ok(session) => Ok(session)
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(session) => session
    Err(error) => raise @posoco.SessionError::Load(error.describe())
  }
}

///|
/// Whole-session replacement remains the canonical compact/fork/recovery
/// operation. Replacing the snapshot and clearing its journal is atomic.
pub impl @posoco.SessionPort for HawdbSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  let result = self.db.with_transaction(fn(tx) {
    match transaction_clear_delta(tx, id) {
      Ok(_) => ()
      Err(reason) => return Err(@hawdb.HawdbError::Codec(reason))
    }
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
/// Append only new owned message rows and an optional metadata override.
/// from_index is an Agent logical cursor, not a physical database index.
pub impl @posoco.SessionPort for HawdbSessionStore with fn checkpoint(
  self,
  id : String,
  checkpoint : @posoco.SessionCheckpoint,
) -> Unit raise @posoco.SessionError {
  let result = self.db.with_transaction(fn(tx) {
    match transaction_append_delta(tx, id, checkpoint) {
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
    match transaction_truncate_delta(tx, id, from_index) {
      Ok(_) => Ok(())
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(_) => ()
    Err(error) => raise @posoco.SessionError::Save(error.describe())
  }
}
