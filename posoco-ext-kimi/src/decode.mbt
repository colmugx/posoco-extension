///|
/// Wire decoder: convert a Kimi Responses API response into a kernel
/// Completion. The shared kit parses items/tool calls/usage/reasoning
/// (reasoning raw items ride `Reasoning.raw` for verbatim replay); this
/// layer adds the kimi specifics: a `max_output_tokens` truncation maps to
/// FinishReason::Length.

///|
/// `status: "incomplete"` with a `max_output_tokens` reason is a length
/// truncation, not a protocol failure. The reason rides `status_details`
/// (documented kimi shape); `incomplete_details` (OpenAI spelling) is
/// accepted as a fallback.
fn kimi_is_length_truncation(resp : Json) -> Bool {
  match resp {
    Json::Object(map) => {
      let status_incomplete = match map.get("status") {
        Some(Json::String("incomplete")) => true
        _ => false
      }
      if !status_incomplete {
        return false
      }
      let reason = match map.get("status_details") {
        Some(Json::Object(details)) => details.get("reason")
        Some(Json::Null) | None =>
          match map.get("incomplete_details") {
            Some(Json::Object(details)) => details.get("reason")
            _ => None
          }
        Some(_) => None
      }
      match reason {
        Some(Json::String("max_output_tokens")) => true
        _ => false
      }
    }
    _ => false
  }
}

///|
/// The shared kit accepts only `status: "completed"`. A length truncation
/// is re-labelled before the kit parse so the stream stays on the success
/// path; the caller overrides the finish reason afterwards.
fn kimi_mark_completed(resp : Json) -> Json {
  match resp {
    Json::Object(map) => {
      let fields : Array[(String, Json)] = []
      for key, value in map {
        if key != "status" {
          fields.push((key, value))
        }
      }
      fields.push(("status", Json::string("completed")))
      Json::object(Map::from_array(fields))
    }
    other => other
  }
}

///|
/// Re-label a max_output_tokens truncation as Length; every other
/// completion keeps the kit-parsed finish reason.
fn apply_kimi_length_truncation(
  completion : @posoco.Completion,
  length_truncated : Bool,
) -> @posoco.Completion {
  if !length_truncated {
    return completion
  }
  @posoco.Completion::Completion(
    content=completion.message.content,
    tool_calls=completion.message.tool_calls,
    reasoning=completion.message.reasoning,
    finish_reason=@posoco.FinishReason::Length,
    usage=completion.usage,
  )
}

///|
/// Decode a complete Responses response into a Completion.
fn decode_responses_response(
  resp_json : Json,
) -> @posoco.Completion raise @posoco.ModelError {
  let length_truncated = kimi_is_length_truncation(resp_json)
  let completion = @responses.parse_responses_response(
    provider="kimi",
    if length_truncated {
      kimi_mark_completed(resp_json)
    } else {
      resp_json
    },
  )
  apply_kimi_length_truncation(completion, length_truncated)
}
