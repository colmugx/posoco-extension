///|
pub let version : Int32 = 1

///|
pub(all) enum Outcome {
  Success(content~ : String, structured~ : Json?)
  Failure(code~ : String, content~ : String, structured~ : Json?)
} derive(Eq, Debug)

///|
pub extend Outcome with Eq::{equal, not_equal}

///|
pub extend Outcome with Debug::{to_repr}

///|
pub(all) enum Message {
  Hello(protocol~ : Int32)
  Invoke(
    input~ : Json,
    tools~ : Array[String],
    max_pending~ : Int32,
    max_frame_bytes~ : Int32
  )
  Request(id~ : Int32, name~ : String, arguments~ : Json)
  Reply(id~ : Int32, outcome~ : Outcome)
  Log(level~ : String, content~ : String)
  Result(outcome~ : Outcome)
  Cancel(reason~ : String)
} derive(Eq, Debug)

///|
pub extend Message with Eq::{equal, not_equal}

///|
pub extend Message with Debug::{to_repr}

///|
pub fn Outcome::to_json(self : Outcome) -> Json {
  let (fields, structured) : (Map[String, Json], Json?) = match self {
    Success(content~, structured~) =>
      (
        { "kind": Json::string("success"), "content": Json::string(content) },
        structured,
      )
    Failure(code~, content~, structured~) =>
      (
        {
          "kind": Json::string("failure"),
          "code": Json::string(code),
          "content": Json::string(content),
        },
        structured,
      )
  }
  match structured {
    Some(value) => fields["structured"] = value
    None => ()
  }
  Json::object(fields)
}

///|
fn get_string(value : Json, key : String) -> String raise ProtocolError {
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(String(text)) => text
        _ => raise Invalid("missing or invalid string: " + key)
      }
    _ => raise Invalid("message must be an object")
  }
}

///|
fn get_value(value : Json, key : String) -> Json raise ProtocolError {
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(v) => v
        None => raise Invalid("missing field: " + key)
      }
    _ => raise Invalid("message must be an object")
  }
}

///|
fn get_positive(value : Json, key : String) -> Int32 raise ProtocolError {
  match get_value(value, key) {
    Number(n, ..) if n >= 1.0 &&
      n <= 2147483647.0 &&
      n == n.to_int().to_double() => n.to_int()
    _ => raise Invalid("expected positive integer: " + key)
  }
}

///|
pub fn Outcome::from_json(value : Json) -> Outcome raise ProtocolError {
  let content = get_string(value, "content")
  let structured = match value {
    Object(fields) => fields.get("structured")
    _ => raise Invalid("outcome must be an object")
  }
  match get_string(value, "kind") {
    "success" => Success(content~, structured~)
    "failure" => Failure(code=get_string(value, "code"), content~, structured~)
    _ => raise Invalid("unknown outcome kind")
  }
}

///|
pub fn Message::to_json(self : Message) -> Json {
  match self {
    Hello(protocol~) => { "type": "hello", "protocol": protocol }
    Invoke(input~, tools~, max_pending~, max_frame_bytes~) =>
      {
        "type": "invoke",
        "input": input,
        "tools": tools,
        "max_pending": max_pending,
        "max_frame_bytes": max_frame_bytes,
      }
    Request(id~, name~, arguments~) =>
      { "type": "request", "id": id, "name": name, "arguments": arguments }
    Reply(id~, outcome~) =>
      { "type": "reply", "id": id, "outcome": outcome.to_json() }
    Log(level~, content~) =>
      { "type": "log", "level": level, "content": content }
    Result(outcome~) => { "type": "result", "outcome": outcome.to_json() }
    Cancel(reason~) => { "type": "cancel", "reason": reason }
  }
}

///|
pub fn Message::from_json(value : Json) -> Message raise ProtocolError {
  match get_string(value, "type") {
    "hello" => Hello(protocol=get_positive(value, "protocol"))
    "invoke" => {
      let tools = match get_value(value, "tools") {
        Array(items) =>
          items.map(item => {
            match item {
              String(name) => name
              _ => raise Invalid("tools must contain only strings")
            }
          })
        _ => raise Invalid("tools must be an array")
      }
      Invoke(
        input=get_value(value, "input"),
        tools~,
        max_pending=get_positive(value, "max_pending"),
        max_frame_bytes=get_positive(value, "max_frame_bytes"),
      )
    }
    "request" =>
      Request(
        id=get_positive(value, "id"),
        name=get_string(value, "name"),
        arguments=get_value(value, "arguments"),
      )
    "reply" =>
      Reply(
        id=get_positive(value, "id"),
        outcome=Outcome::from_json(get_value(value, "outcome")),
      )
    "log" =>
      Log(
        level=get_string(value, "level"),
        content=get_string(value, "content"),
      )
    "result" => Result(outcome=Outcome::from_json(get_value(value, "outcome")))
    "cancel" => Cancel(reason=get_string(value, "reason"))
    _ => raise Invalid("unknown message type")
  }
}
