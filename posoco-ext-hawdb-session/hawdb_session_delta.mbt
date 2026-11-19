///|
/// B3 incremental journal overlay, preserving the B2 snapshot table.
///
/// Existing posoco_sessions rows remain valid. Append/checkpoint store one
/// owned, lossless message document per row without rewriting that snapshot.
/// A head row holds the delta sequence and optional metadata replacement.
/// save() atomically replaces the base and clears its delta journal. Sequence
/// numbers are storage-local; SessionCheckpoint.from_index is NOT a SQL row id.

///|
fn ensure_delta_table(
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
fn ensure_delta_schema(db : @hawdb.Database) -> Result[Unit, String] {
  match ensure_delta_table(
    db,
    "posoco_session_delta_heads",
    "CREATE TABLE posoco_session_delta_heads (id TEXT PRIMARY KEY, next_seq BIGINT, metadata TEXT)",
    ["id", "next_seq", "metadata"],
    ["text", "bigint", "text"],
  ) {
    Ok(_) => ()
    Err(reason) => return Err(reason)
  }
  ensure_delta_table(
    db,
    "posoco_session_delta_rows",
    "CREATE TABLE posoco_session_delta_rows (entry_key TEXT PRIMARY KEY, id TEXT, seq BIGINT, document TEXT)",
    ["entry_key", "id", "seq", "document"],
    ["text", "text", "bigint", "text"],
  )
}

///|
/// The metadata override is a normal metadata-only canonical JSONL document.
/// Empty text is the sentinel for preserving the legacy base metadata.
fn delta_metadata_text(metadata : Map[String, Json]) -> String {
  @codec.session_to_jsonl({ messages: [], metadata, })
}

///|
fn decode_delta_metadata(text : String) -> Result[Map[String, Json], String] {
  let result = match decode_document(text) {
    Ok(session) => session
    Err(reason) => return Err(reason)
  }
  if !result.messages.is_empty() {
    return Err("HawDB delta metadata contains messages")
  }
  Ok(result.metadata)
}

///|
/// Single-message envelopes reuse the proven lossless v2 JSONL codec, so
/// ToolOutcome, reasoning raw JSON, and arbitrary Unicode round-trip.
fn encode_delta_message(message : @posoco.Message) -> String {
  @codec.session_to_jsonl({ messages: [message], metadata: Map([]), })
}

///|
fn decode_delta_message(text : String) -> Result[@posoco.Message, String] {
  let session = match decode_document(text) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  if session.messages.length() != 1 || !session.metadata.is_empty() {
    return Err("HawDB delta journal row must contain exactly one message")
  }
  Ok(session.messages[0])
}

///|
fn transaction_delta_head(
  tx : @hawdb.Transaction,
  id : String,
) -> Result[(Int64, String)?, String] {
  let rows = match tx.query_sql(
    "SELECT next_seq, metadata FROM posoco_session_delta_heads WHERE id = $1",
    [@hawdb.Value::Text(id)],
  ) {
    Ok(rows) => rows
    Err(error) => return Err(error.describe())
  }
  if rows.rows.length() == 0 {
    return Ok(None)
  }
  if rows.rows.length() != 1 {
    return Err("duplicate HawDB session delta head")
  }
  match (rows.get(0, "next_seq"), rows.get(0, "metadata")) {
    (Some(@hawdb.Value::Int(seq)), Some(@hawdb.Value::Text(metadata))) if seq >= 0L =>
      Ok(Some((seq, metadata)))
    _ => Err("corrupt HawDB session delta head")
  }
}

///|
/// Stable collision-free key, including ids with punctuation or Unicode.
/// Sequence is physical append order, independent of the logical from_index.
fn delta_row_key(id : String, seq : Int64) -> String {
  id.length().to_string() + ":" + id + ":" + seq.to_string()
}

///|
fn transaction_load_complete(
  tx : @hawdb.Transaction,
  id : String,
) -> Result[@posoco.Session, String] {
  let base = match transaction_load(tx, id) {
    Ok(session) => session
    Err(reason) => return Err(reason)
  }
  let head = match transaction_delta_head(tx, id) {
    Ok(head) => head
    Err(reason) => return Err(reason)
  }
  let rows = match tx.query_sql(
    "SELECT seq, document FROM posoco_session_delta_rows WHERE id = $1 ORDER BY seq",
    [@hawdb.Value::Text(id)],
  ) {
    Ok(rows) => rows
    Err(error) => return Err(error.describe())
  }
  let (expected, override_text) = match head {
    Some((seq, metadata)) => (seq, metadata)
    None => (0L, "")
  }
  if rows.rows.length().to_int64() != expected {
    return Err("HawDB session delta row count disagrees with head")
  }
  let messages = base.messages.copy()
  for i in 0..<rows.rows.length() {
    let seq = match rows.get(i, "seq") {
      Some(@hawdb.Value::Int(value)) => value
      _ => return Err("invalid HawDB session delta sequence")
    }
    if seq != i.to_int64() {
      return Err("noncontiguous HawDB session delta sequence")
    }
    let document = match rows.get(i, "document") {
      Some(@hawdb.Value::Text(value)) => value
      _ => return Err("invalid HawDB session delta document")
    }
    match decode_delta_message(document) {
      Ok(message) => messages.push(message)
      Err(reason) => return Err(reason)
    }
  }
  let metadata = if override_text == "" {
    base.metadata
  } else {
    match decode_delta_metadata(override_text) {
      Ok(metadata) => metadata
      Err(reason) => return Err(reason)
    }
  }
  Ok({ messages, metadata, })
}

///|
/// Each checkpoint appends O(new messages), not O(entire session).
/// All delta inserts and any metadata override share one HawDB transaction.
fn transaction_append_delta(
  tx : @hawdb.Transaction,
  id : String,
  checkpoint : @posoco.SessionCheckpoint,
) -> Result[Unit, String] {
  if checkpoint.messages.is_empty() && checkpoint.metadata is None {
    return Ok(())
  }
  let existing = match transaction_delta_head(tx, id) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let (start_seq, previous_metadata) = match existing {
    Some((seq, metadata)) => (seq, metadata)
    None => (0L, "")
  }
  let next_seq = start_seq + checkpoint.messages.length().to_int64()
  if next_seq < start_seq {
    return Err("HawDB session delta sequence overflow")
  }
  let metadata = match checkpoint.metadata {
    Some(value) => delta_metadata_text(value)
    None => previous_metadata
  }

  // Create/update the lightweight head in the same write transaction as the
  // journal rows. A failed insert/commit cannot expose a partial checkpoint.
  let head_update = match existing {
    None =>
      tx.query_sql(
        "INSERT INTO posoco_session_delta_heads (id, next_seq, metadata) VALUES ($1, $2, $3)",
        [
          @hawdb.Value::Text(id),
          @hawdb.Value::Int(next_seq),
          @hawdb.Value::Text(metadata),
        ],
      )
    Some(_) =>
      tx.query_sql(
        "UPDATE posoco_session_delta_heads SET next_seq = $1, metadata = $2 WHERE id = $3",
        [
          @hawdb.Value::Int(next_seq),
          @hawdb.Value::Text(metadata),
          @hawdb.Value::Text(id),
        ],
      )
  }
  match head_update {
    Ok(_) => ()
    Err(error) => return Err(error.describe())
  }
  let mut seq = start_seq
  for message in checkpoint.messages {
    match tx.query_sql(
      "INSERT INTO posoco_session_delta_rows (entry_key, id, seq, document) VALUES ($1, $2, $3, $4)",
      [
        @hawdb.Value::Text(delta_row_key(id, seq)),
        @hawdb.Value::Text(id),
        @hawdb.Value::Int(seq),
        @hawdb.Value::Text(encode_delta_message(message)),
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
fn transaction_clear_delta(
  tx : @hawdb.Transaction,
  id : String,
) -> Result[Unit, String] {
  match tx.query_sql(
    "DELETE FROM posoco_session_delta_rows WHERE id = $1",
    [@hawdb.Value::Text(id)],
  ) {
    Ok(_) => ()
    Err(error) => return Err(error.describe())
  }
  match tx.query_sql(
    "DELETE FROM posoco_session_delta_heads WHERE id = $1",
    [@hawdb.Value::Text(id)],
  ) {
    Ok(_) => Ok(())
    Err(error) => Err(error.describe())
  }
}

///|
/// Truncating within the append-only segment removes only its tail rows.
/// Truncation into an older legacy snapshot rewrites that base once; a later
/// B-stage migration can eliminate that exceptional legacy operation.
fn transaction_truncate_delta(
  tx : @hawdb.Transaction,
  id : String,
  from_index : Int32,
) -> Result[Unit, String] {
  let base = match transaction_load(tx, id) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let head = match transaction_delta_head(tx, id) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let (delta_count, metadata_override) = match head {
    Some((count, metadata)) => (count, metadata)
    None => (0L, "")
  }
  let base_len = base.messages.length().to_int64()
  let full_len = base_len + delta_count
  let keep = if from_index < 0 {
    0L
  } else if from_index.to_int64() > full_len {
    full_len
  } else {
    from_index.to_int64()
  }
  if keep == full_len {
    return Ok(())
  }
  if keep < base_len {
    let retained : Array[@posoco.Message] = []
    for i in 0..<keep.to_int() {
      retained.push(base.messages[i])
    }
    let metadata = if metadata_override == "" {
      base.metadata
    } else {
      match decode_delta_metadata(metadata_override) {
        Ok(metadata) => metadata
        Err(reason) => return Err(reason)
      }
    }
    match transaction_clear_delta(tx, id) {
      Ok(_) => ()
      Err(reason) => return Err(reason)
    }
    return transaction_write(tx, id, { messages: retained, metadata, })
  }
  let new_delta_count = keep - base_len
  match tx.query_sql(
    "DELETE FROM posoco_session_delta_rows WHERE id = $1 AND seq >= $2",
    [@hawdb.Value::Text(id), @hawdb.Value::Int(new_delta_count)],
  ) {
    Ok(_) => ()
    Err(error) => return Err(error.describe())
  }
  match head {
    None =>
      if new_delta_count == 0L {
        Ok(())
      } else {
        Err("missing HawDB session delta head during truncate")
      }
    Some(_) =>
      match tx.query_sql(
        "UPDATE posoco_session_delta_heads SET next_seq = $1 WHERE id = $2",
        [@hawdb.Value::Int(new_delta_count), @hawdb.Value::Text(id)],
      ) {
        Ok(_) => Ok(())
        Err(error) => Err(error.describe())
      }
  }
}
