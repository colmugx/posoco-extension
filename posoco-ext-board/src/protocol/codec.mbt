///|
fn decode_json(line : String) -> Result[Json, BoardProtocolError] {
  Ok(@json.parse(line)) catch {
    error => Err(InvalidJson(error.to_string()))
  }
}

///|
fn object_fields(
  value : Json,
  context : String,
) -> Result[Map[String, Json], BoardProtocolError] {
  match value {
    Json::Object(fields) => Ok(fields)
    _ => Err(InvalidFrame("\{context} must be a JSON object"))
  }
}

///|
fn required_string(
  fields : Map[String, Json],
  key : String,
) -> Result[String, BoardProtocolError] {
  match fields.get(key) {
    Some(Json::String(value)) => Ok(value)
    Some(_) => Err(InvalidFrame("field '\{key}' must be a string"))
    None => Err(InvalidFrame("missing field '\{key}'"))
  }
}

///|
fn required_int64(
  fields : Map[String, Json],
  key : String,
) -> Result[Int64, BoardProtocolError] {
  match fields.get(key) {
    Some(Json::Number(value, ..)) =>
      if value < 0 ||
        value > 9007199254740991.0 ||
        value.to_int64().to_double() != value {
        Err(InvalidFrame("field '\{key}' must be a nonnegative safe integer"))
      } else {
        Ok(value.to_int64())
      }
    Some(_) => Err(InvalidFrame("field '\{key}' must be a number"))
    None => Err(InvalidFrame("missing field '\{key}'"))
  }
}

///|
fn required_int(
  fields : Map[String, Json],
  key : String,
) -> Result[Int, BoardProtocolError] {
  match required_int64(fields, key) {
    Ok(value) if value <= 2147483647L => Ok(value.to_int())
    Ok(_) => Err(InvalidFrame("field '\{key}' exceeds integer range"))
    Err(error) => Err(error)
  }
}

///|
fn required_bool(
  fields : Map[String, Json],
  key : String,
) -> Result[Bool, BoardProtocolError] {
  match fields.get(key) {
    Some(Json::True) => Ok(true)
    Some(Json::False) => Ok(false)
    Some(_) => Err(InvalidFrame("field '\{key}' must be a boolean"))
    None => Err(InvalidFrame("missing field '\{key}'"))
  }
}

///|
fn optional_string(
  fields : Map[String, Json],
  key : String,
) -> Result[String?, BoardProtocolError] {
  match fields.get(key) {
    None | Some(Json::Null) => Ok(None)
    Some(Json::String(value)) => Ok(Some(value))
    Some(_) => Err(InvalidFrame("field '\{key}' must be a string or null"))
  }
}

///|
fn optional_int64(
  fields : Map[String, Json],
  key : String,
) -> Result[Int64?, BoardProtocolError] {
  match fields.get(key) {
    None | Some(Json::Null) => Ok(None)
    Some(Json::Number(value, ..)) => Ok(Some(value.to_int64()))
    Some(_) => Err(InvalidFrame("field '\{key}' must be a number or null"))
  }
}

///|
fn scope_to_json(scope : BoardEventScope) -> Json {
  Json::object({
    "session_id": match scope.session_id {
      Some(value) => Json::string(value)
      None => Json::null()
    },
    "run_id": match scope.run_id {
      Some(value) => Json::string(value)
      None => Json::null()
    },
    "turn_id": match scope.turn_id {
      Some(value) => Json::string(value)
      None => Json::null()
    },
  })
}

///|
fn scope_from_json(value : Json) -> Result[BoardEventScope, BoardProtocolError] {
  match object_fields(value, "event scope") {
    Err(error) => Err(error)
    Ok(fields) => {
      let session_id = match optional_string(fields, "session_id") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let run_id = match optional_string(fields, "run_id") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let turn_id = match optional_string(fields, "turn_id") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok({ session_id, run_id, turn_id, })
    }
  }
}

///|
pub fn BoardHello::to_json(self : BoardHello) -> Json {
  Json::object({
    "type": Json::string("hello"),
    "last_seq": Json::number(self.last_seq.to_double()),
    "protocol_version": Json::number(self.protocol_version.to_double()),
  })
}

///|
pub fn BoardClientCommand::to_json(self : BoardClientCommand) -> Json {
  Json::object({
    "type": Json::string("command"),
    "command_id": Json::string(self.command_id),
    "name": Json::string(self.name),
    "expected_revision": Json::number(self.expected_revision.to_double()),
    "args": self.args,
  })
}

///|
pub fn BoardCommandResult::to_json(self : BoardCommandResult) -> Json {
  let fields : Map[String, Json] = {
    "type": Json::string("command_result"),
    "command_id": Json::string(self.command_id),
    "accepted": Json::boolean(self.accepted),
  }
  match self.error {
    Some(value) => fields["error"] = Json::string(value)
    None => ()
  }
  match self.current_revision {
    Some(value) => fields["current_revision"] = Json::number(value.to_double())
    None => ()
  }
  Json::object(fields)
}

///|
pub fn BoardWireEvent::to_json(self : BoardWireEvent) -> Json {
  Json::object({
    "type": Json::string("event"),
    "seq": Json::number(self.seq.to_double()),
    "board_revision": Json::number(self.board_revision.to_double()),
    "kind": Json::string(self.kind),
    "scope": match self.scope {
      Some(value) => scope_to_json(value)
      None => Json::null()
    },
    "payload": self.payload,
  })
}

///|
pub fn BoardSnapshot::to_json(self : BoardSnapshot) -> Json {
  Json::object({
    "type": Json::string("snapshot"),
    "protocol_version": Json::number(self.protocol_version.to_double()),
    "last_seq": Json::number(self.last_seq.to_double()),
    "board_revision": Json::number(self.board_revision.to_double()),
    "payload": self.payload,
  })
}

///|
pub fn encode_client_frame(frame : BoardClientFrame) -> String {
  match frame {
    Hello(value) => value.to_json().stringify()
    Command(value) => value.to_json().stringify()
  }
}

///|
pub fn encode_server_frame(frame : BoardServerFrame) -> String {
  match frame {
    CommandResult(value) => value.to_json().stringify()
    Event(value) => value.to_json().stringify()
    Snapshot(value) => value.to_json().stringify()
    ResyncRequired(reason~, current_seq~) =>
      Json::object({
        "type": "resync_required",
        "reason": reason.to_json(),
        "current_seq": Json::number(current_seq.to_double()),
      }).stringify()
    Error(code~, message~) =>
      Json::object({
        "type": "error",
        "code": code.to_json(),
        "message": message.to_json(),
      }).stringify()
  }
}

///|
pub fn decode_client_frame(
  line : String,
) -> Result[BoardClientFrame, BoardProtocolError] {
  let value = match decode_json(line) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let fields = match object_fields(value, "client frame") {
    Ok(fields) => fields
    Err(error) => return Err(error)
  }
  let kind = match required_string(fields, "type") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match kind {
    "hello" => {
      let last_seq = match required_int64(fields, "last_seq") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let version = match required_int(fields, "protocol_version") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if version != protocol_version() {
        Err(UnsupportedVersion(expected=protocol_version(), got=version))
      } else {
        Ok(Hello({ last_seq, protocol_version: version, }))
      }
    }
    "command" => {
      let command_id = match required_string(fields, "command_id") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let name = match required_string(fields, "name") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let expected_revision = match
        required_int64(fields, "expected_revision") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let args = match fields.get("args") {
        Some(value) => value
        None => return Err(InvalidFrame("missing field 'args'"))
      }
      Ok(Command({ command_id, name, expected_revision, args, }))
    }
    other => Err(InvalidFrame("unsupported client frame type '\{other}'"))
  }
}

///|
pub fn decode_server_frame(
  line : String,
) -> Result[BoardServerFrame, BoardProtocolError] {
  let value = match decode_json(line) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let fields = match object_fields(value, "server frame") {
    Ok(fields) => fields
    Err(error) => return Err(error)
  }
  let kind = match required_string(fields, "type") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match kind {
    "resync_required" => {
      let reason = match required_string(fields, "reason") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let current_seq = match required_int64(fields, "current_seq") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(ResyncRequired(reason~, current_seq~))
    }
    "error" => {
      let code = match required_string(fields, "code") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let message = match required_string(fields, "message") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(Error(code~, message~))
    }
    "command_result" => {
      let command_id = match required_string(fields, "command_id") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let accepted = match required_bool(fields, "accepted") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let error = match optional_string(fields, "error") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let current_revision = match optional_int64(fields, "current_revision") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(CommandResult({ command_id, accepted, error, current_revision, }))
    }
    "event" => {
      let seq = match required_int64(fields, "seq") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let board_revision = match required_int64(fields, "board_revision") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let event_kind = match required_string(fields, "kind") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let scope = match fields.get("scope") {
        None | Some(Json::Null) => None
        Some(value) =>
          match scope_from_json(value) {
            Ok(scope) => Some(scope)
            Err(error) => return Err(error)
          }
      }
      let payload = match fields.get("payload") {
        Some(value) => value
        None => return Err(InvalidFrame("missing field 'payload'"))
      }
      Ok(Event({ seq, board_revision, kind: event_kind, scope, payload, }))
    }
    "snapshot" => {
      let version = match required_int(fields, "protocol_version") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if version != protocol_version() {
        return Err(UnsupportedVersion(expected=protocol_version(), got=version))
      }
      let last_seq = match required_int64(fields, "last_seq") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let board_revision = match required_int64(fields, "board_revision") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let payload = match fields.get("payload") {
        Some(value) => value
        None => return Err(InvalidFrame("missing field 'payload'"))
      }
      Ok(
        Snapshot({
          protocol_version: version,
          last_seq,
          board_revision,
          payload,
        }),
      )
    }
    other => Err(InvalidFrame("unsupported server frame type '\{other}'"))
  }
}
