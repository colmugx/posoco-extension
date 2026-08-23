///|
/// Double bounds of MoonBit's 32-bit Int range, used to gate Json counts.
const NMEM_INT_MIN_AS_DOUBLE : Double = -2147483648.0

///|
const NMEM_INT_MAX_AS_DOUBLE : Double = 2147483647.0

///|
/// Field of a Json object; `None` for non-objects and missing keys.
fn json_field(data : Json, key : String) -> Json? {
  match data {
    Json::Object(fields) =>
      if fields.contains(key) {
        Some(fields[key])
      } else {
        None
      }
    _ => None
  }
}

///|
/// Integral value of a Json number (MoonBit parses numbers as Double,
/// upstream checks Number.isInteger on the wire value). Finiteness is
/// implied: NaN fails floor == self and infinities exceed the bound.
/// Counts beyond the 32-bit Int range are conservatively rejected (upstream
/// would accept them as JS integers): an unrepresentable count reads as
/// "absent", so the sync engine retries or reconciles instead of trusting it.
fn json_int_value(data : Json) -> Int? {
  match data {
    Json::Number(value, ..) =>
      if value.floor() == value &&
        value >= NMEM_INT_MIN_AS_DOUBLE &&
        value <= NMEM_INT_MAX_AS_DOUBLE {
        Some(value.to_int())
      } else {
        None
      }
    _ => None
  }
}

///|
fn json_is_safe_integer(data : Json) -> Bool {
  json_int_value(data) is Some(_)
}

///|
/// Append acknowledgement (upstream isThreadAppendAck): success === true
/// plus integral messages_added and total_messages. Negative integers count
/// as integers, mirroring Number.isInteger.
pub fn is_thread_append_ack(data : Json) -> Bool {
  match
    (
      json_field(data, "success"),
      json_field(data, "messages_added"),
      json_field(data, "total_messages"),
    ) {
    (Some(Json::True), Some(added), Some(total)) =>
      json_is_safe_integer(added) && json_is_safe_integer(total)
    _ => false
  }
}

///|
/// Checkpointed append acknowledgement (upstream isCheckpointedAppendAck):
/// an append ack that also reports append_mode === "checkpointed".
pub fn is_checkpointed_append_ack(data : Json) -> Bool {
  is_thread_append_ack(data) &&
  json_field(data, "append_mode") is Some(Json::String("checkpointed"))
}

///|
/// Checkpoint conflict response (upstream isCheckpointConflictResponse):
/// error_code === "checkpoint_conflict".
pub fn is_checkpoint_conflict(data : Json) -> Bool {
  json_field(data, "error_code") is Some(Json::String("checkpoint_conflict"))
}

///|
/// Thread-already-exists response (upstream isThreadAlreadyExistsResponse):
/// HTTP 409, or the serialized body mentions the phrase case-insensitively.
pub fn is_thread_already_exists(status : Int, data : Json) -> Bool {
  if status == 409 {
    true
  } else {
    let text = data.stringify().to_lower()
    text.contains("thread already exists") ||
    text.contains("already exists in space")
  }
}

///|
/// Thread-not-found response (upstream isThreadNotFound): error_code ===
/// "thread_not_found", HTTP 404, or the serialized body mentions the phrase
/// case-insensitively.
pub fn is_thread_not_found(status : Int, data : Json) -> Bool {
  if json_field(data, "error_code") is Some(Json::String("thread_not_found")) {
    true
  } else if status == 404 {
    true
  } else {
    data.stringify().to_lower().contains("thread not found")
  }
}

///|
/// Create acknowledgement (upstream isThreadCreateAck): body.thread is an
/// object whose thread_id equals the expected id.
pub fn is_thread_create_ack(data : Json, expected_thread_id : String) -> Bool {
  match json_field(data, "thread") {
    Some(thread) =>
      match thread {
        Json::Object(_) =>
          match json_field(thread, "thread_id") {
            Some(Json::String(id)) => id == expected_thread_id
            _ => false
          }
        _ => false
      }
    None => false
  }
}

///|
/// Remote message count reported by a create response (upstream
/// threadCreateRemoteCount minus its expected-id gate, which callers apply
/// through is_thread_create_ack): thread.message_count when it is a
/// non-negative integer, else the top-level messages array length, else
/// `None`.
pub fn thread_create_remote_count(data : Json) -> Int? {
  match json_field(data, "thread") {
    Some(thread) =>
      match thread {
        Json::Object(_) =>
          match json_field(thread, "message_count") {
            Some(count) =>
              match json_int_value(count) {
                Some(value) =>
                  if value >= 0 {
                    Some(value)
                  } else {
                    messages_length(data)
                  }
                None => messages_length(data)
              }
            None => messages_length(data)
          }
        _ => None
      }
    None => None
  }
}

///|
fn messages_length(data : Json) -> Int? {
  match json_field(data, "messages") {
    Some(Json::Array(items)) => Some(items.length())
    _ => None
  }
}
