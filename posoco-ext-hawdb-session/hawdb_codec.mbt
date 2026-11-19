///|
fn content_to_json(content : @posoco.Content) -> Json {
  match content {
    @posoco.Content::Text(text) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("text")),
          ("text", Json::string(text)),
        ]),
      )
    @posoco.Content::Image(media_type~, data~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("image")),
          ("media_type", Json::string(media_type)),
          ("data", Json::string(data)),
        ]),
      )
  }
}

fn content_from_json(json : Json) -> @posoco.Content? {
  match json {
    Json::Object(map) =>
      if map.contains("type") {
        match map["type"] {
          Json::String(s) if s == "text" =>
            match map.get("text") {
              Some(Json::String(t)) => Some(@posoco.Content::Text(t))
              _ => None
            }
          Json::String(s) if s == "image" =>
            match (map.get("media_type"), map.get("data")) {
              (Some(Json::String(mt)), Some(Json::String(d))) =>
                Some(@posoco.Content::Image(media_type=mt, data=d))
              _ => None
            }
          _ => None
        }
      } else {
        None
      }
    _ => None
  }
}

fn tool_call_to_json(call : @posoco.ToolCall) -> Json {
  Json::object(
    Map::from_array([
      ("call_id", Json::string(call.call_id.to_string())),
      ("name", Json::string(call.name.to_string())),
      ("arguments", call.arguments),
    ]),
  )
}

fn tool_call_from_json(json : Json) -> @posoco.ToolCall? {
  match json {
    Json::Object(map) => {
      let id_str = match map.get("call_id") {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
      let name_str = match map.get("name") {
        Some(Json::String(s)) => Some(s)
        _ => None
      }
      let arguments = map.get("arguments")
      match (id_str, name_str, arguments) {
        (Some(id), Some(name), Some(args)) =>
          Some(@posoco.ToolCall::{
            call_id: @posoco.CallId::unchecked(id),
            name: @posoco.ToolName::unchecked(name),
            arguments: args,
          })
        _ => None
      }
    }
    _ => None
  }
}

fn parse_content_array(arr : Array[Json]) -> Array[@posoco.Content]? {
  let result : Array[@posoco.Content] = []
  for item in arr {
    match content_from_json(item) {
      Some(c) => result.push(c)
      None => return None
    }
  }
  Some(result)
}

fn parse_tool_call_array(arr : Array[Json]) -> Array[@posoco.ToolCall]? {
  let result : Array[@posoco.ToolCall] = []
  for item in arr {
    match tool_call_from_json(item) {
      Some(c) => result.push(c)
      None => return None
    }
  }
  Some(result)
}

fn hawdb_reason_json(reason : @posoco.NotExecutedReason) -> Json {
  let fields : Map[String, Json] = Map([])
  match reason {
    @posoco.NotExecutedReason::UnknownTool => fields["kind"] = Json::string("unknown_tool")
    @posoco.NotExecutedReason::NotOffered => fields["kind"] = Json::string("not_offered")
    @posoco.NotExecutedReason::OwnerNotAllowed => fields["kind"] = Json::string("owner_not_allowed")
    @posoco.NotExecutedReason::InvocationLimit => fields["kind"] = Json::string("invocation_limit")
    @posoco.NotExecutedReason::PolicyConflict => fields["kind"] = Json::string("policy_conflict")
    @posoco.NotExecutedReason::Revoked => fields["kind"] = Json::string("revoked")
    @posoco.NotExecutedReason::SupersededByMessage =>
      fields["kind"] = Json::string("superseded_by_message")
    @posoco.NotExecutedReason::SchemaMismatch(json_path~, expected~, actual~) => {
      fields["kind"] = Json::string("schema_mismatch")
      fields["json_path"] = Json::string(json_path)
      fields["expected"] = Json::string(expected)
      fields["actual"] = Json::string(actual)
    }
    @posoco.NotExecutedReason::RejectedByHook(reason~) => {
      fields["kind"] = Json::string("rejected_by_hook")
      fields["reason"] = Json::string(reason)
    }
  }
  Json::object(fields)
}

fn hawdb_reason_from_json(json : Json) -> @posoco.NotExecutedReason? {
  match json {
    Json::Object(fields) =>
      match fields.get("kind") {
        Some(Json::String("unknown_tool")) => Some(@posoco.NotExecutedReason::UnknownTool)
        Some(Json::String("not_offered")) => Some(@posoco.NotExecutedReason::NotOffered)
        Some(Json::String("owner_not_allowed")) => Some(@posoco.NotExecutedReason::OwnerNotAllowed)
        Some(Json::String("invocation_limit")) => Some(@posoco.NotExecutedReason::InvocationLimit)
        Some(Json::String("policy_conflict")) => Some(@posoco.NotExecutedReason::PolicyConflict)
        Some(Json::String("revoked")) => Some(@posoco.NotExecutedReason::Revoked)
        Some(Json::String("superseded_by_message")) =>
          Some(@posoco.NotExecutedReason::SupersededByMessage)
        Some(Json::String("schema_mismatch")) =>
          match (fields.get("json_path"), fields.get("expected"), fields.get("actual")) {
            (Some(Json::String(path)), Some(Json::String(expected)), Some(Json::String(actual))) =>
              Some(@posoco.NotExecutedReason::SchemaMismatch(json_path=path, expected~, actual~))
            _ => None
          }
        Some(Json::String("rejected_by_hook")) =>
          match fields.get("reason") {
            Some(Json::String(reason)) => Some(@posoco.NotExecutedReason::RejectedByHook(reason~))
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

fn hawdb_outcome_json(outcome : @posoco.ToolOutcome) -> Json {
  let fields : Map[String, Json] = Map([])
  match outcome {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      fields["kind"] = Json::string("success")
      fields["content"] = Json::string(content)
      match structured {
        Some(data) => fields["structured"] = data
        None => ()
      }
    }
    @posoco.ToolOutcome::SuccessWithAttachments(content~, structured~, attachments~) => {
      fields["kind"] = Json::string("success_with_attachments")
      fields["content"] = Json::string(content)
      fields["attachments"] = Json::array(attachments.map(content_to_json))
      match structured {
        Some(data) => fields["structured"] = data
        None => ()
      }
    }
    @posoco.ToolOutcome::ToolReportedError(content~, structured~) => {
      fields["kind"] = Json::string("tool_reported_error")
      fields["content"] = Json::string(content)
      match structured {
        Some(data) => fields["structured"] = data
        None => ()
      }
    }
    @posoco.ToolOutcome::RuntimeFailure(error_category~, message~) => {
      fields["kind"] = Json::string("runtime_failure")
      fields["error_category"] = Json::string(error_category)
      fields["message"] = Json::string(message)
    }
    @posoco.ToolOutcome::NotExecuted(reason~, original_call_id~) => {
      fields["kind"] = Json::string("not_executed")
      fields["reason"] = hawdb_reason_json(reason)
      fields["original_call_id"] = Json::string(original_call_id.to_string())
    }
  }
  Json::object(fields)
}

fn hawdb_outcome_from_json(json : Json) -> @posoco.ToolOutcome? {
  match json {
    Json::Object(fields) => {
      let structured = fields.get("structured")
      match fields.get("kind") {
        Some(Json::String("success")) =>
          match fields.get("content") {
            Some(Json::String(content)) => Some(@posoco.ToolOutcome::Success(content~, structured~))
            _ => None
          }
        Some(Json::String("success_with_attachments")) =>
          match (fields.get("content"), fields.get("attachments")) {
            (Some(Json::String(content)), Some(Json::Array(parts))) =>
              match parse_content_array(parts) {
                Some(attachments) =>
                  Some(@posoco.ToolOutcome::SuccessWithAttachments(content~, structured~, attachments~))
                None => None
              }
            _ => None
          }
        Some(Json::String("tool_reported_error")) =>
          match fields.get("content") {
            Some(Json::String(content)) =>
              Some(@posoco.ToolOutcome::ToolReportedError(content~, structured~))
            _ => None
          }
        Some(Json::String("runtime_failure")) =>
          match (fields.get("error_category"), fields.get("message")) {
            (Some(Json::String(error_category)), Some(Json::String(message))) =>
              Some(@posoco.ToolOutcome::RuntimeFailure(error_category~, message~))
            _ => None
          }
        Some(Json::String("not_executed")) =>
          match (fields.get("reason"), fields.get("original_call_id")) {
            (Some(reason_json), Some(Json::String(id))) =>
              match hawdb_reason_from_json(reason_json) {
                Some(reason) =>
                  Some(@posoco.ToolOutcome::NotExecuted(
                    reason~, original_call_id=@posoco.CallId::unchecked(id),
                  ))
                None => None
              }
            _ => None
          }
        _ => None
      }
    }
    _ => None
  }
}

fn hawdb_finish_json(reason : @posoco.FinishReason) -> Json {
  match reason {
    @posoco.FinishReason::Stop => Json::object({"kind": Json::string("stop")})
    @posoco.FinishReason::Length => Json::object({"kind": Json::string("length")})
    @posoco.FinishReason::ToolCalls => Json::object({"kind": Json::string("tool_calls")})
    @posoco.FinishReason::Other(value) =>
      Json::object({"kind": Json::string("other"), "value": Json::string(value)})
  }
}

fn hawdb_finish_from_json(json : Json) -> @posoco.FinishReason? {
  match json {
    Json::Object(fields) =>
      match fields.get("kind") {
        Some(Json::String("stop")) => Some(@posoco.FinishReason::Stop)
        Some(Json::String("length")) => Some(@posoco.FinishReason::Length)
        Some(Json::String("tool_calls")) => Some(@posoco.FinishReason::ToolCalls)
        Some(Json::String("other")) =>
          match fields.get("value") {
            Some(Json::String(s)) => Some(@posoco.FinishReason::Other(s))
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
fn hawdb_message_json(message : @posoco.Message) -> Json {
  let record : Map[String, Json] = Map([])
  match message {
    @posoco.Message::SystemMessage(content~) => {
      record["kind"] = Json::string("system")
      record["content"] = Json::array(content.map(content_to_json))
    }
    @posoco.Message::UserMessage(content~) => {
      record["kind"] = Json::string("user")
      record["content"] = Json::array(content.map(content_to_json))
    }
    @posoco.Message::AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) => {
      record["kind"] = Json::string("assistant")
      record["content"] = Json::array(content.map(content_to_json))
      record["tool_calls"] = Json::array(tool_calls.map(tool_call_to_json))
      record["finish_reason"] = hawdb_finish_json(finish_reason)
      match reasoning {
        Some(value) => {
          record["reasoning"] = Json::object({
            "content": Json::string(value.content),
            "raw": match value.raw {
              Some(raw) => raw
              None => Json::null()
            },
          })
        }
        None => record["reasoning"] = Json::null()
      }
    }
    @posoco.Message::ToolMessage(call_id~, tool_name~, outcome~) => {
      record["kind"] = Json::string("tool")
      record["call_id"] = Json::string(call_id.to_string())
      record["tool_name"] = Json::string(tool_name.to_string())
      record["outcome"] = hawdb_outcome_json(outcome)
    }
  }
  Json::object(record)
}

///|
fn hawdb_message_from_json(json : Json) -> @posoco.Message? {
  match json {
    Json::Object(fields) => {
      match fields.get("kind") {
        Some(Json::String("system")) =>
          match fields.get("content") {
            Some(Json::Array(items)) =>
              match parse_content_array(items) {
                Some(content) => Some(@posoco.Message::SystemMessage(content~))
                None => None
              }
            _ => None
          }
        Some(Json::String("user")) =>
          match fields.get("content") {
            Some(Json::Array(items)) =>
              match parse_content_array(items) {
                Some(content) => Some(@posoco.Message::UserMessage(content~))
                None => None
              }
            _ => None
          }
        Some(Json::String("assistant")) =>
          match (fields.get("content"), fields.get("tool_calls"),
            fields.get("reasoning"), fields.get("finish_reason")) {
            (Some(Json::Array(items)), Some(Json::Array(calls)), raw_reasoning, Some(raw_finish)) => {
              let content = match parse_content_array(items) {
                Some(value) => value
                None => return None
              }
              let tool_calls = match parse_tool_call_array(calls) {
                Some(value) => value
                None => return None
              }
              let finish_reason = match hawdb_finish_from_json(raw_finish) {
                Some(value) => value
                None => return None
              }
              let reasoning = match raw_reasoning {
                Some(Json::Null) => None
                Some(Json::Object(value)) =>
                  match (value.get("content"), value.get("raw")) {
                    (Some(Json::String(content)), Some(Json::Null)) =>
                      Some(@posoco.Reasoning::{content, raw: None})
                    (Some(Json::String(content)), Some(raw)) =>
                      Some(@posoco.Reasoning::{content, raw: Some(raw)})
                    _ => return None
                  }
                _ => return None
              }
              Some(@posoco.Message::AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~))
            }
            _ => None
          }
        Some(Json::String("tool")) =>
          match (fields.get("call_id"), fields.get("tool_name"), fields.get("outcome")) {
            (Some(Json::String(id)), Some(Json::String(name)), Some(raw)) =>
              match hawdb_outcome_from_json(raw) {
                Some(outcome) =>
                  Some(@posoco.Message::ToolMessage(
                    call_id=@posoco.CallId::unchecked(id),
                    tool_name=@posoco.ToolName::unchecked(name),
                    outcome~,
                  ))
                None => None
              }
            _ => None
          }
        _ => None
      }
    }
    _ => None
  }
}

///|
fn hawdb_encode_message(message : @posoco.Message) -> String {
  hawdb_message_json(message).stringify()
}

///|
fn hawdb_decode_message(document : String) -> Result[@posoco.Message, String] {
  let value = @json.parse(document, reject_duplicate_keys=true) catch {
    _ => return Err("invalid HawDB message JSON")
  }
  match hawdb_message_from_json(value) {
    Some(message) => Ok(message)
    None => Err("invalid HawDB message fields")
  }
}

///|
fn hawdb_encode_metadata(metadata : Map[String, Json]) -> String {
  Json::object(metadata).stringify()
}

///|
fn hawdb_decode_metadata(document : String) -> Result[Map[String, Json], String] {
  let value = @json.parse(document, reject_duplicate_keys=true) catch {
    _ => return Err("invalid HawDB metadata JSON")
  }
  match value {
    Json::Object(fields) => Ok(fields)
    _ => Err("HawDB metadata must be an object")
  }
}
