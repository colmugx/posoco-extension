///|
fn checkpoint_payload(checkpoint : @posoco.SessionCheckpoint) -> String {
  let data : Map[String, Json] = Map([])
  data["from_index"] = Json::number(checkpoint.from_index)
  data["messages"] = Json::array(checkpoint.messages.map(fn(message) {
    hawdb_message_json(message)
  }))
  data["metadata"] = match checkpoint.metadata {
    Some(metadata) => Json::object(metadata)
    None => Json::null()
  }
  Json::object(data).stringify()
}

///|
fn receipt_key(id : String, operation_id : String) -> String {
  id.length().to_string() + ":" + id + ":" + operation_id
}

///|
fn read_receipt(
  tx : @hawdb.Transaction,
  id : String,
  operation_id : String,
) -> Result[(Int64, String, Int64)?, String] {
  let rows = match tx.query_sql(
    "SELECT expected_revision, payload, resulting_revision FROM posoco_hawdb_operations WHERE entry_key = $1",
    [@hawdb.Value::Text(receipt_key(id, operation_id))],
  ) {
    Ok(value) => value
    Err(error) => return Err(error.describe())
  }
  if rows.rows.is_empty() {
    return Ok(None)
  }
  if rows.rows.length() != 1 {
    return Err("duplicate checkpoint receipt")
  }
  match (
    rows.get(0, "expected_revision"),
    rows.get(0, "payload"),
    rows.get(0, "resulting_revision"),
  ) {
    (
      Some(@hawdb.Value::Int(expected)),
      Some(@hawdb.Value::Text(payload)),
      Some(@hawdb.Value::Int(resulting)),
    ) if expected >= 0L && resulting > expected =>
      Ok(Some((expected, payload, resulting)))
    _ => Err("corrupt checkpoint receipt")
  }
}

///|
fn write_receipt(
  tx : @hawdb.Transaction,
  id : String,
  operation_id : String,
  expected_revision : Int64,
  payload : String,
  resulting_revision : Int64,
) -> Result[Unit, String] {
  let result = tx.query_sql(
    "INSERT INTO posoco_hawdb_operations (entry_key, id, expected_revision, payload, resulting_revision) VALUES ($1, $2, $3, $4, $5)",
    [
      @hawdb.Value::Text(receipt_key(id, operation_id)),
      @hawdb.Value::Text(id),
      @hawdb.Value::Int(expected_revision),
      @hawdb.Value::Text(payload),
      @hawdb.Value::Int(resulting_revision),
    ],
  )
  match result {
    Ok(_) => Ok(())
    Err(error) => Err(error.describe())
  }
}

///|
/// Revision checks and receipt insertion execute in the same write transaction.
fn apply_guarded_checkpoint(
  tx : @hawdb.Transaction,
  id : String,
  expected_revision : Int64,
  operation_id : String,
  checkpoint : @posoco.SessionCheckpoint,
) -> Result[Int64, String] {
  if expected_revision < 0L || operation_id == "" {
    return Err("invalid checkpoint revision or operation id")
  }
  let payload = checkpoint_payload(checkpoint)
  let previous = match read_receipt(tx, id, operation_id) {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  match previous {
    Some((revision, saved_payload, resulting)) => {
      if revision == expected_revision && saved_payload == payload {
        return Ok(resulting)
      }
      return Err("checkpoint operation id conflict")
    }
    None => ()
  }
  let actual_revision = match read_session_head(tx, id) {
    Ok(Some((_, _, revision))) => revision
    Ok(None) => 0L
    Err(reason) => return Err(reason)
  }
  if actual_revision != expected_revision {
    return Err("checkpoint revision conflict")
  }
  if actual_revision == 9223372036854775807L {
    return Err("session revision overflow")
  }
  match append_checkpoint(tx, id, checkpoint) {
    Ok(_) => ()
    Err(reason) => return Err(reason)
  }
  let resulting_revision = if checkpoint.messages.is_empty() && checkpoint.metadata is None {
    actual_revision
  } else {
    actual_revision + 1L
  }
  match write_receipt(tx, id, operation_id, expected_revision, payload, resulting_revision) {
    Ok(_) => Ok(resulting_revision)
    Err(reason) => Err(reason)
  }
}

///|
pub fn HawdbSessionStore::revision(
  self : HawdbSessionStore,
  id : String,
) -> Int64 raise @posoco.SessionError {
  let result = self.db.with_read_transaction(fn(tx) {
    match read_session_head(tx, id) {
      Ok(Some((_, _, revision))) => Ok(revision)
      Ok(None) => Ok(0L)
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(value) => value
    Err(error) => raise @posoco.SessionError::Load(error.describe())
  }
}

///|
/// An operation id identifies exactly one checkpoint payload for a session.
pub fn HawdbSessionStore::checkpoint_guarded(
  self : HawdbSessionStore,
  id : String,
  expected_revision : Int64,
  operation_id : String,
  checkpoint : @posoco.SessionCheckpoint,
) -> Int64 raise @posoco.SessionError {
  let result = self.db.with_transaction(fn(tx) {
    match apply_guarded_checkpoint(tx, id, expected_revision, operation_id, checkpoint) {
      Ok(value) => Ok(value)
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(value) => value
    Err(error) => raise @posoco.SessionError::Save(error.describe())
  }
}
