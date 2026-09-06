///|
/// Server-side error object of a response: `{code, message, data?}`.
pub(all) struct ZcodeRpcError {
  code : Int
  message : String
  data : Json?
} derive(Eq, Debug)

///|
/// One line of the ZCode Protocol's line-delimited JSON (no `jsonrpc`
/// field). Client request ids are numbers, server request ids are strings
/// like "server-1" — both stay as raw `Json`.
/// `method_name` (not `method`): "method" is a reserved word in the current
/// toolchain and warns everywhere; the wire field itself stays "method".
pub(all) enum ZcodeWire {
  Request(id~ : Json, method_name~ : String, params~ : Json?)
  Response(id~ : Json, result~ : Json?, error~ : ZcodeRpcError?)
  Notification(method_name~ : String, params~ : Json?)
} derive(Eq, Debug)

///|
/// Decode one wire line. Classification (probed against zcode 0.16.5):
/// object with "method" → "id" present means Request, else Notification;
/// without "method" → "id" plus "result"/"error" means Response; anything
/// else (unparsable, non-object, id-less payload, bare id) is Err.
pub fn zcode_wire_decode(line : String) -> Result[ZcodeWire, String] {
  let parsed : Result[Json, String] = Ok(@json.parse(line)) catch {
    err => Err(err.to_string())
  }
  match parsed {
    Err(message) => Err(message)
    Ok(json) =>
      match json {
        Json::Object(map) => zcode_wire_classify(map)
        _ => Err("zcode wire: line is not a JSON object")
      }
  }
}

///|
fn zcode_wire_classify(map : Map[String, Json]) -> Result[ZcodeWire, String] {
  if map.contains("method") {
    match map["method"] {
      Json::String(method_name) => {
        let params = map.get("params")
        if map.contains("id") {
          Ok(Request(id=map["id"], method_name~, params~))
        } else {
          Ok(Notification(method_name~, params~))
        }
      }
      _ => Err("zcode wire: 'method' must be a string")
    }
  } else if map.contains("id") {
    if map.contains("result") || map.contains("error") {
      let error = match map.get("error") {
        Some(raw) => Some(zcode_rpc_error_of(raw))
        None => None
      }
      Ok(Response(id=map["id"], result=map.get("result"), error~))
    } else {
      Err("zcode wire: response without 'result' or 'error'")
    }
  } else {
    Err("zcode wire: line has neither 'method' nor 'id'")
  }
}

///|
/// Defensive read of a response error object; missing fields fall back to
/// zero values instead of failing the whole response.
fn zcode_rpc_error_of(raw : Json) -> ZcodeRpcError {
  match raw {
    Json::Object(map) => {
      let code = match map.get("code") {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => 0
      }
      let message = match map.get("message") {
        Some(Json::String(s)) => s
        _ => ""
      }
      { code, message, data: map.get("data"), }
    }
    _ => { code: 0, message: "", data: None, }
  }
}

///|
/// Serialize to one wire line; JSON stringification never emits raw newlines.
pub fn ZcodeWire::to_line(self : ZcodeWire) -> String {
  let json = match self {
    Request(id~, method_name~, params~) => {
      let obj : Map[String, Json] = Map::from_array([
        ("id", id),
        ("method", Json::string(method_name)),
      ])
      match params {
        Some(p) => obj["params"] = p
        None => ()
      }
      Json::object(obj)
    }
    Response(id~, result~, error~) => {
      let obj : Map[String, Json] = Map::from_array([("id", id)])
      match result {
        Some(r) => obj["result"] = r
        None => ()
      }
      match error {
        Some(e) => {
          let err_obj : Map[String, Json] = Map::from_array([
            ("code", Json::number(e.code.to_double())),
            ("message", Json::string(e.message)),
          ])
          match e.data {
            Some(d) => err_obj["data"] = d
            None => ()
          }
          obj["error"] = Json::object(err_obj)
        }
        None => ()
      }
      Json::object(obj)
    }
    Notification(method_name~, params~) => {
      let obj : Map[String, Json] = Map::from_array([
        ("method", Json::string(method_name)),
      ])
      match params {
        Some(p) => obj["params"] = p
        None => ()
      }
      Json::object(obj)
    }
  }
  json.stringify()
}

///|
/// Field access helpers shared by events.mbt and registry.mbt.
fn json_field(j : Json, key : String) -> Json? {
  match j {
    Json::Object(map) => map.get(key)
    _ => None
  }
}

///|
fn json_field_string(j : Json, key : String) -> String? {
  match json_field(j, key) {
    Some(Json::String(s)) => Some(s)
    _ => None
  }
}

///|
/// Missing or non-numeric fields read as 0 (usage accounting tolerates it).
fn json_field_int(j : Json, key : String) -> Int {
  match json_field(j, key) {
    Some(Json::Number(n, ..)) => n.to_int()
    _ => 0
  }
}
