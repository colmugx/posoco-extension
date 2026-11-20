///|
/// HawDB session persistence uses a session row and ordered message rows.

///|
fn catalog_text_is(value : @hawdb.Value?, expected : String) -> Bool {
  match value {
    Some(@hawdb.Value::Text(actual)) => actual == expected
    _ => false
  }
}

fn ensure_hawdb_table(
  db : @hawdb.Database,
  table : String,
  ddl : String,
  names : Array[String],
  types : Array[String],
) -> Result[Unit, String] {
  let present = match db.query_sql(
    "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
    [@hawdb.Value::Text(table)],
  ) {
    Ok(rows) => rows
    Err(error) => return Err(error.describe())
  }
  if present.rows.length() == 0 {
    match db.query_sql(ddl, []) {
      Ok(_) => ()
      Err(error) => return Err(error.describe())
    }
  } else if present.rows.length() != 1 ||
    !catalog_text_is(present.get(0, "table_type"), "BASE TABLE") {
    return Err("invalid HawDB session journal table: " + table)
  }
  let cols = match db.query_sql(
    "SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 ORDER BY ordinal_position",
    [@hawdb.Value::Text(table)],
  ) {
    Ok(rows) => rows
    Err(error) => return Err(error.describe())
  }
  if cols.rows.length() != names.length() {
    return Err("HawDB session journal schema drift: " + table)
  }
  for i in 0..<names.length() {
    if !catalog_text_is(cols.get(i, "column_name"), names[i]) ||
      !catalog_text_is(cols.get(i, "data_type"), types[i]) {
      return Err("HawDB session journal schema drift: " + table)
    }
  }
  let indexes = match db.query_sql(
    "SELECT indexname FROM pg_indexes WHERE schemaname = 'public' AND tablename = $1",
    [@hawdb.Value::Text(table)],
  ) {
    Ok(rows) => rows
    Err(error) => return Err(error.describe())
  }
  if indexes.rows.length() != 1 ||
    !catalog_text_is(indexes.get(0, "indexname"), table + "_pkey") {
    return Err("HawDB session journal primary key drift: " + table)
  }
  Ok(())
}


///|
fn ensure_hawdb_schema(db : @hawdb.Database) -> Result[Unit, String] {
  match ensure_hawdb_table(
    db,
    "posoco_hawdb_sessions",
    "CREATE TABLE posoco_hawdb_sessions (id TEXT PRIMARY KEY, metadata TEXT, next_seq BIGINT, revision BIGINT)",
    ["id", "metadata", "next_seq", "revision"],
    ["text", "text", "bigint", "bigint"],
  ) {
    Ok(_) => ()
    Err(reason) => return Err(reason)
  }
  ensure_hawdb_table(
    db,
    "posoco_hawdb_messages",
    "CREATE TABLE posoco_hawdb_messages (entry_key TEXT PRIMARY KEY, id TEXT, seq BIGINT, document TEXT)",
    ["entry_key", "id", "seq", "document"],
    ["text", "text", "bigint", "text"],
  )
}

///|
fn ensure_hawdb_receipts(db : @hawdb.Database) -> Result[Unit, String] {
  ensure_hawdb_table(
    db,
    "posoco_hawdb_operations",
    "CREATE TABLE posoco_hawdb_operations (entry_key TEXT PRIMARY KEY, id TEXT, expected_revision BIGINT, payload TEXT, resulting_revision BIGINT)",
    ["entry_key", "id", "expected_revision", "payload", "resulting_revision"],
    ["text", "text", "bigint", "text", "bigint"],
  )
}

///|
pub(all) struct HawdbSessionStore {
  db : @hawdb.Database
  mut current_id : String?
}

///|
fn finish_session_open(db : @hawdb.Database) -> Result[HawdbSessionStore, String] {
  let schema = match ensure_hawdb_schema(db) {
    Ok(_) => ensure_hawdb_receipts(db)
    Err(reason) => Err(reason)
  }
  match schema {
    Ok(_) => Ok({ db, current_id: None, })
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
pub fn HawdbSessionStore::check_id(id : String) -> Result[Unit, String] {
  if id.is_empty() {
    return Err("session id must not be empty")
  }
  if id == "." || id == ".." {
    return Err("session id must not be a relative path segment")
  }
  if id.contains("/") || id.contains("\\") {
    return Err("session id must not contain path separators")
  }
  Ok(())
}

///|
fn empty_session() -> @posoco.Session {
  { messages: [], metadata: Map([]), }
}

///|
fn message_key(id : String, seq : Int64) -> String {
  id.length().to_string() + ":" + id + ":" + seq.to_string()
}

///|
fn read_session_head(
  tx : @hawdb.Transaction,
  id : String,
) -> Result[(Int64, Map[String, Json], Int64)?, String] {
  let rows = match tx.query_sql(
    "SELECT next_seq, metadata, revision FROM posoco_hawdb_sessions WHERE id = $1",
    [@hawdb.Value::Text(id)],
  ) {
    Ok(value) => value
    Err(error) => return Err(error.describe())
  }
  if rows.rows.is_empty() {
    return Ok(None)
  }
  if rows.rows.length() != 1 {
    return Err("duplicate session head")
  }
  match (rows.get(0, "next_seq"), rows.get(0, "metadata"), rows.get(0, "revision")) {
    (
      Some(@hawdb.Value::Int(next_seq)),
      Some(@hawdb.Value::Text(data)),
      Some(@hawdb.Value::Int(revision)),
    ) if next_seq >= 0L && revision >= 0L =>
      match hawdb_decode_metadata(data) {
        Ok(metadata) => Ok(Some((next_seq, metadata, revision)))
        Err(reason) => Err(reason)
      }
    _ => Err("invalid session head")
  }
}

///|
fn read_session(
  tx : @hawdb.Transaction,
  id : String,
) -> Result[@posoco.Session, String] {
  let head = match read_session_head(tx, id) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let rows = match tx.query_sql(
    "SELECT seq, document FROM posoco_hawdb_messages WHERE id = $1 ORDER BY seq",
    [@hawdb.Value::Text(id)],
  ) {
    Ok(value) => value
    Err(error) => return Err(error.describe())
  }
  let (expected, metadata) = match head {
    Some((count, metadata, _)) => (count, metadata)
    None => {
      if !rows.rows.is_empty() {
        return Err("orphan session messages")
      }
      return Ok(empty_session())
    }
  }
  if rows.rows.length().to_int64() != expected {
    return Err("session message count mismatch")
  }
  let messages : Array[@posoco.Message] = []
  for i in 0..<rows.rows.length() {
    match (rows.get(i, "seq"), rows.get(i, "document")) {
      (Some(@hawdb.Value::Int(seq)), Some(@hawdb.Value::Text(data))) if seq == i.to_int64() =>
        match hawdb_decode_message(data) {
          Ok(message) => messages.push(message)
          Err(reason) => return Err(reason)
        }
      _ => return Err("invalid session message sequence or content")
    }
  }
  Ok({ messages, metadata, })
}

///|
fn clear_session(
  tx : @hawdb.Transaction,
  id : String,
) -> Result[Unit, String] {
  match tx.query_sql(
    "DELETE FROM posoco_hawdb_messages WHERE id = $1",
    [@hawdb.Value::Text(id)],
  ) {
    Ok(_) => ()
    Err(error) => return Err(error.describe())
  }
  match tx.query_sql(
    "DELETE FROM posoco_hawdb_sessions WHERE id = $1",
    [@hawdb.Value::Text(id)],
  ) {
    Ok(_) => Ok(())
    Err(error) => Err(error.describe())
  }
}

///|
fn write_head(
  tx : @hawdb.Transaction,
  id : String,
  next_seq : Int64,
  metadata : Map[String, Json],
  revision : Int64,
  exists : Bool,
) -> Result[Unit, String] {
  let document = hawdb_encode_metadata(metadata)
  let result = if exists {
    tx.query_sql(
      "UPDATE posoco_hawdb_sessions SET next_seq = $1, metadata = $2, revision = $3 WHERE id = $4",
      [
        @hawdb.Value::Int(next_seq),
        @hawdb.Value::Text(document),
        @hawdb.Value::Int(revision),
        @hawdb.Value::Text(id),
      ],
    )
  } else {
    tx.query_sql(
      "INSERT INTO posoco_hawdb_sessions (id, metadata, next_seq, revision) VALUES ($1, $2, $3, $4)",
      [
        @hawdb.Value::Text(id),
        @hawdb.Value::Text(document),
        @hawdb.Value::Int(next_seq),
        @hawdb.Value::Int(revision),
      ],
    )
  }
  match result {
    Ok(_) => Ok(())
    Err(error) => Err(error.describe())
  }
}

///|
fn insert_messages(
  tx : @hawdb.Transaction,
  id : String,
  from : Int64,
  messages : Array[@posoco.Message],
) -> Result[Unit, String] {
  let mut seq = from
  for message in messages {
    match tx.query_sql(
      "INSERT INTO posoco_hawdb_messages (entry_key, id, seq, document) VALUES ($1, $2, $3, $4)",
      [
        @hawdb.Value::Text(message_key(id, seq)),
        @hawdb.Value::Text(id),
        @hawdb.Value::Int(seq),
        @hawdb.Value::Text(hawdb_encode_message(message)),
      ],
    ) {
      Ok(_) => ()
      Err(error) => return Err(error.describe())
    }
    seq = seq + 1L
  }
  Ok(())
}

///|
fn write_session(
  tx : @hawdb.Transaction,
  id : String,
  session : @posoco.Session,
) -> Result[Unit, String] {
  let revision = match read_session_head(tx, id) {
    Ok(Some((_, _, previous))) => {
      if previous == 9223372036854775807L {
        return Err("session revision overflow")
      }
      previous + 1L
    }
    Ok(None) => 1L
    Err(reason) => return Err(reason)
  }
  match clear_session(tx, id) {
    Ok(_) => ()
    Err(reason) => return Err(reason)
  }
  match write_head(tx, id, session.messages.length().to_int64(), session.metadata, revision, false) {
    Ok(_) => ()
    Err(reason) => return Err(reason)
  }
  insert_messages(tx, id, 0L, session.messages)
}

///|
/// The checkpoint cursor is logical; the storage sequence is independent.
fn append_checkpoint(
  tx : @hawdb.Transaction,
  id : String,
  checkpoint : @posoco.SessionCheckpoint,
) -> Result[Unit, String] {
  let head = match read_session_head(tx, id) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if checkpoint.messages.is_empty() && checkpoint.metadata is None {
    return match head {
      Some(_) => Ok(())
      None => write_head(tx, id, 0L, Map([]), 1L, false)
    }
  }
  let (start, previous_metadata, revision) = match head {
    Some((count, metadata, revision)) => (count, metadata, revision)
    None => (0L, Map([]), 0L)
  }
  if revision == 9223372036854775807L {
    return Err("session revision overflow")
  }
  let count = checkpoint.messages.length().to_int64()
  let next = start + count
  if next < start {
    return Err("session sequence overflow")
  }
  let metadata = match checkpoint.metadata {
    Some(value) => value
    None => previous_metadata
  }
  match write_head(tx, id, next, metadata, revision + 1L, head is Some(_)) {
    Ok(_) => ()
    Err(reason) => return Err(reason)
  }
  insert_messages(tx, id, start, checkpoint.messages)
}

///|
fn truncate_session(
  tx : @hawdb.Transaction,
  id : String,
  from_index : Int32,
) -> Result[Unit, String] {
  let head = match read_session_head(tx, id) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let (count, metadata, revision) = match head {
    Some(value) => value
    None => return write_head(tx, id, 0L, Map([]), 1L, false)
  }
  let keep = if from_index < 0 {
    0L
  } else if from_index.to_int64() > count {
    count
  } else {
    from_index.to_int64()
  }
  if keep == count {
    return Ok(())
  }
  match tx.query_sql(
    "DELETE FROM posoco_hawdb_messages WHERE id = $1 AND seq >= $2",
    [@hawdb.Value::Text(id), @hawdb.Value::Int(keep)],
  ) {
    Ok(_) => ()
    Err(error) => return Err(error.describe())
  }
  if revision == 9223372036854775807L {
    return Err("session revision overflow")
  }
  write_head(tx, id, keep, metadata, revision + 1L, true)
}

///|
pub extend HawdbSessionStore with @posoco.SessionPort::{
  load, save, append_messages, checkpoint, truncate,
}

///|
pub impl @posoco.SessionPort for HawdbSessionStore with fn load(
  self,
  id : String,
) -> @posoco.Session raise @posoco.SessionError {
  match HawdbSessionStore::check_id(id) {
    Ok(_) => ()
    Err(reason) => raise @posoco.SessionError::Load(reason)
  }
  let result = self.db.with_read_transaction(fn(tx) {
    match read_session(tx, id) {
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
pub impl @posoco.SessionPort for HawdbSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit raise @posoco.SessionError {
  match HawdbSessionStore::check_id(id) {
    Ok(_) => ()
    Err(reason) => raise @posoco.SessionError::Save(reason)
  }
  let result = self.db.with_transaction(fn(tx) {
    match write_session(tx, id, session) {
      Ok(_) => Ok(())
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(_) => self.current_id = Some(id)
    Err(error) => raise @posoco.SessionError::Save(error.describe())
  }
}

///|
pub impl @posoco.SessionPort for HawdbSessionStore with fn checkpoint(
  self,
  id : String,
  checkpoint : @posoco.SessionCheckpoint,
) -> Unit raise @posoco.SessionError {
  match HawdbSessionStore::check_id(id) {
    Ok(_) => ()
    Err(reason) => raise @posoco.SessionError::Save(reason)
  }
  let result = self.db.with_transaction(fn(tx) {
    match append_checkpoint(tx, id, checkpoint) {
      Ok(_) => Ok(())
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(_) => self.current_id = Some(id)
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
  self.checkpoint(id, { from_index, messages: messages.to_owned(), metadata: None })
}

///|
pub impl @posoco.SessionPort for HawdbSessionStore with fn truncate(
  self,
  id : String,
  from_index : Int32,
) -> Unit raise @posoco.SessionError {
  match HawdbSessionStore::check_id(id) {
    Ok(_) => ()
    Err(reason) => raise @posoco.SessionError::Save(reason)
  }
  let result = self.db.with_transaction(fn(tx) {
    match truncate_session(tx, id, from_index) {
      Ok(_) => Ok(())
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(_) => self.current_id = Some(id)
    Err(error) => raise @posoco.SessionError::Save(error.describe())
  }
}
