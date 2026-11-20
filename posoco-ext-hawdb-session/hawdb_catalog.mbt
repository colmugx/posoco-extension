///|
pub(all) struct HawdbSessionSummary {
  id : String
  name : String?
  title : String?
  model : String?
  effort : String?
  cwd : String?
}

///|
fn nonempty_text(value : Json?) -> String? {
  match value {
    Some(Json::String(text)) if !text.is_empty() => Some(text)
    _ => None
  }
}

///|
fn session_title_text(input : String) -> String? {
  let output = StringBuilder()
  let mut pending_space = false
  let mut count = 0
  for ch in input {
    if count >= 50 {
      break
    }
    let code = ch.to_int()
    if code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d {
      pending_space = true
    } else {
      if pending_space && count > 0 {
        output.write_char(' ')
        count += 1
      }
      pending_space = false
      if count < 50 {
        output.write_char(ch)
        count += 1
      }
    }
  }
  let value = output.to_string()
  if value.is_empty() { None } else { Some(value) }
}

///|
pub fn hawdb_display_title(summary : HawdbSessionSummary) -> String {
  match summary.name {
    Some(value) if !value.is_empty() => value
    _ =>
      match summary.title {
        Some(value) if !value.is_empty() => value
        _ => summary.id
      }
  }
}

///|
pub fn HawdbSessionStore::list_ids(
  self : HawdbSessionStore,
) -> Array[String] raise @posoco.SessionError {
  let result = self.db.query_sql(
    "SELECT id FROM posoco_hawdb_sessions ORDER BY id", [],
  )
  match result {
    Ok(rows) => {
      let ids : Array[String] = []
      for index in 0..<rows.rows.length() {
        match rows.get(index, "id") {
          Some(@hawdb.Value::Text(id)) =>
            match HawdbSessionStore::check_id(id) {
              Ok(_) => ids.push(id)
              Err(reason) => raise @posoco.SessionError::Load(reason)
            }
          _ => raise @posoco.SessionError::Load("invalid session id in catalog")
        }
      }
      ids
    }
    Err(error) => raise @posoco.SessionError::Load(error.describe())
  }
}

///|
pub fn HawdbSessionStore::summary(
  self : HawdbSessionStore,
  id : String,
) -> HawdbSessionSummary raise @posoco.SessionError {
  let session = self.load(id)
  let title = match nonempty_text(session.metadata.get(@posoco.SESSION_TITLE_METADATA_KEY)) {
    Some(text) => session_title_text(text)
    None => None
  }
  let (model, effort) = match session.metadata.get("posoco.model_selection") {
    Some(Json::Object(fields)) =>
      (nonempty_text(fields.get("slot_id")), nonempty_text(fields.get("effort")))
    _ => (None, None)
  }
  {
    id,
    name: nonempty_text(session.metadata.get("name")),
    title,
    model,
    effort,
    cwd: nonempty_text(session.metadata.get("cetas.cwd")),
  }
}

///|
pub fn HawdbSessionStore::set_session_name(
  self : HawdbSessionStore,
  id : String,
  name : String,
) -> Unit raise @posoco.SessionError {
  match HawdbSessionStore::check_id(id) {
    Ok(_) => ()
    Err(reason) => raise @posoco.SessionError::Save(reason)
  }
  let result = self.db.with_transaction(fn(tx) {
    let head = match read_session_head(tx, id) {
      Ok(value) => value
      Err(reason) => return Err(@hawdb.HawdbError::Codec(reason))
    }
    let (length, metadata, revision) = match head {
      Some(value) => value
      None => (0L, Map([]), 0L)
    }
    if revision == 9223372036854775807L {
      return Err(@hawdb.HawdbError::Codec("session revision overflow"))
    }
    let updated = metadata.copy()
    updated["name"] = Json::string(name)
    match write_head(tx, id, length, updated, revision + 1L, head is Some(_)) {
      Ok(_) => Ok(())
      Err(reason) => Err(@hawdb.HawdbError::Codec(reason))
    }
  })
  match result {
    Ok(_) => self.current_id = Some(id)
    Err(error) => raise @posoco.SessionError::Save(error.describe())
  }
}
