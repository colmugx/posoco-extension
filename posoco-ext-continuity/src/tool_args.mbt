fn continuity_argument_object(call : @posoco.ToolCall) -> Map[String, Json]? {
  match call.arguments {
    Json::Object(fields) => Some(fields)
    _ => None
  }
}

fn continuity_field_string(
  fields : Map[String, Json],
  name : String,
) -> String? {
  if !fields.contains(name) { return None }
  match fields[name] {
    Json::String(value) => Some(value)
    _ => None
  }
}

fn continuity_field_string_array(
  fields : Map[String, Json],
  name : String,
) -> Array[String] {
  if !fields.contains(name) { return [] }
  match fields[name] {
    Json::Array(values) => {
      let out : Array[String] = []
      for value in values {
        match value {
          Json::String(text) => out.push(text)
          _ => ()
        }
      }
      out
    }
    _ => []
  }
}

fn continuity_parse_cursor(text : String) -> Int? {
  if text == "" { return Some(0) }
  let mut value = 0
  for ch in text {
    if ch < '0' || ch > '9' { return None }
    value = value * 10 + (ch.to_int() - '0'.to_int())
  }
  Some(value)
}

fn continuity_option_present[T](value : T?) -> Bool {
  match value {
    Some(_) => true
    None => false
  }
}

fn continuity_tool_error(message : String) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::ToolReportedError(content=message, structured=None)
}

fn continuity_tool_success(
  content : String,
  structured : Json,
) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::Success(content~, structured=Some(structured))
}

fn continuity_current_session(self : ContinuityExtension) -> String? {
  if !self.turn_active { return None }
  self.active_session_id
}
