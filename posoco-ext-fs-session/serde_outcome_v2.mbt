///|
/// Version-2 lossless encoding for canonical Posoco kernel tool outcomes.
/// Legacy JSONL fields remain readable, but a v2 outcome is authoritative
/// and malformed v2 data MUST fail closed instead of degrading to text.
fn reason_json_v2(reason : @posoco.NotExecutedReason) -> Json {
  let fields : Map[String, Json] = Map([])
  match reason {
    @posoco.NotExecutedReason::UnknownTool => fields["kind"] = Json::string("unknown_tool")
    @posoco.NotExecutedReason::NotOffered => fields["kind"] = Json::string("not_offered")
    @posoco.NotExecutedReason::OwnerNotAllowed => fields["kind"] = Json::string("owner_not_allowed")
    @posoco.NotExecutedReason::InvocationLimit => fields["kind"] = Json::string("invocation_limit")
    @posoco.NotExecutedReason::PolicyConflict => fields["kind"] = Json::string("policy_conflict")
    @posoco.NotExecutedReason::Revoked => fields["kind"] = Json::string("revoked")
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

///|
fn reason_from_json_v2(json : Json) -> @posoco.NotExecutedReason? {
  match json {
    Json::Object(fields) =>
      match fields.get("kind") {
        Some(Json::String("unknown_tool")) => Some(@posoco.NotExecutedReason::UnknownTool)
        Some(Json::String("not_offered")) => Some(@posoco.NotExecutedReason::NotOffered)
        Some(Json::String("owner_not_allowed")) => Some(@posoco.NotExecutedReason::OwnerNotAllowed)
        Some(Json::String("invocation_limit")) => Some(@posoco.NotExecutedReason::InvocationLimit)
        Some(Json::String("policy_conflict")) => Some(@posoco.NotExecutedReason::PolicyConflict)
        Some(Json::String("revoked")) => Some(@posoco.NotExecutedReason::Revoked)
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

///|
fn outcome_json_v2(outcome : @posoco.ToolOutcome) -> Json {
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
      fields["reason"] = reason_json_v2(reason)
      fields["original_call_id"] = Json::string(original_call_id.to_string())
    }
  }
  Json::object(fields)
}

///|
fn outcome_from_json_v2(json : Json) -> @posoco.ToolOutcome? {
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
              match reason_from_json_v2(reason_json) {
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

///|
/// Unlike the legacy finish_reason string, this also preserves Other("stop").
fn finish_json_v2(reason : @posoco.FinishReason) -> Json {
  match reason {
    @posoco.FinishReason::Stop => Json::object({"kind": Json::string("stop")})
    @posoco.FinishReason::Length => Json::object({"kind": Json::string("length")})
    @posoco.FinishReason::ToolCalls => Json::object({"kind": Json::string("tool_calls")})
    @posoco.FinishReason::Other(value) =>
      Json::object({"kind": Json::string("other"), "value": Json::string(value)})
  }
}

///|
fn finish_from_json_v2(json : Json) -> @posoco.FinishReason? {
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
