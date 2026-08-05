///|
/// sse.mbt — SSE parsing for OpenAI Responses API streaming.
///
/// Pure classification types and functions for Server-Sent Events.
/// Package-visible so callers in the same package can use them directly.

///|
/// Pure classification for stream termination; used by the HTTP loop and
/// offline tests so EOF is never inferred from accumulated content.
priv enum StreamTermination {
  ExplicitTerminal
  CleanEof
  TransportFailure
}

///|
fn classify_stream_termination(
  termination : StreamTermination,
) -> @posoco.ModelError? {
  match termination {
    ExplicitTerminal => None
    CleanEof =>
      Some(
        @posoco.ModelError::ResponseParse(
          "OpenAI SSE truncated (stage=eof, terminal_marker=missing)",
        ),
      )
    TransportFailure =>
      Some(
        @posoco.ModelError::Transport(
          "OpenAI transport failure (stage=read_stream)",
        ),
      )
  }
}

///|
/// Reject incomplete tool-call builders before delegating JSON assembly.
fn validate_stream_tool_calls(
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  for tc in acc.tool_calls {
    if tc.id == "" {
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=tool.id, category=missing)",
      )
    }
    if tc.name == "" {
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=tool.name, category=missing)",
      )
    }
    if tc.arguments_json == "" {
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=tool.arguments, category=missing)",
      )
    }
    let _ : Json = @json.parse(tc.arguments_json) catch {
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "OpenAI SSE parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{tc.arguments_json.length()})",
        )
    }
  }
}

///|
/// Parse an SSE event data string into StreamChunk(s) and feed to accumulator.
fn process_sse_event(
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool raise @posoco.ModelError {
  let event_json : Json = @json.parse(data) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=json, payload_chars=\{data.length()})",
      )
  }
  let event_type = match event_json {
    Json::Object(map) =>
      match map.get("type") {
        Some(Json::String(s)) => s
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI SSE parse failure (stage=event_type, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI SSE parse failure (stage=event_type, category=missing)",
          )
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=event, category=not_object)",
      )
  }
  match event_type {
    "response.output_text.delta" => {
      let token = extract_sse_string_field(event_json, "delta")
      let chunk = @posoco.StreamChunk::TextDelta(token~)
      on_chunk(chunk)
      acc.push(chunk)
      false
    }
    "response.reasoning.delta" => {
      let token = extract_sse_string_field(event_json, "delta")
      let chunk = @posoco.StreamChunk::ReasoningDelta(token~)
      on_chunk(chunk)
      acc.push(chunk)
      false
    }
    "response.function_call_arguments.delta" => {
      let index = extract_sse_int_field(event_json, "output_index")
      let delta = extract_sse_string_field(event_json, "delta")
      let chunk = @posoco.StreamChunk::ToolCallDelta(
        index~,
        id=None,
        name=None,
        arguments_delta=Some(delta),
      )
      on_chunk(chunk)
      acc.push(chunk)
      false
    }
    "response.output_item.added" => {
      match extract_sse_output_item(event_json) {
        Some((idx, fc_id, fc_name)) => {
          let chunk = @posoco.StreamChunk::ToolCallDelta(
            index=idx,
            id=Some(fc_id),
            name=Some(fc_name),
            arguments_delta=None,
          )
          on_chunk(chunk)
          acc.push(chunk)
        }
        None => ()
      }
      false
    }
    "response.completed" => {
      let response_json = extract_sse_response(event_json, "completed")
      validate_openai_terminal_response(response_json, "completed.")
      match extract_usage(response_json) {
        Some(usage) => {
          let usage_chunk = @posoco.StreamChunk::Usage(
            input_tokens=usage.input_tokens.unwrap_or(0),
            output_tokens=usage.output_tokens.unwrap_or(0),
            total_tokens=usage.total_tokens.unwrap_or(0),
          )
          on_chunk(usage_chunk)
          acc.push(usage_chunk)
        }
        None => ()
      }
      let reason = extract_finish_from_completed(response_json)
      if reason is @posoco.FinishReason::ToolCalls && acc.tool_calls.is_empty() {
        raise @posoco.ModelError::ResponseParse(
          "OpenAI SSE parse failure (stage=tool.events, category=missing)",
        )
      }
      let finish_chunk = @posoco.StreamChunk::Finish(reason=reason.to_string())
      on_chunk(finish_chunk)
      acc.push(finish_chunk)
      true
    }
    "response.failed" =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE terminal failure (stage=response.failed, category=provider_error)",
      )
    "response.incomplete" =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE terminal failure (stage=response.incomplete, category=not_completed)",
      )
    "error" =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE terminal failure (stage=error, category=provider_error)",
      )
    _ => false
  }
}

///|
/// Extract the nested response object from a terminal SSE event.
fn extract_sse_response(
  event_json : Json,
  event_stage : String,
) -> Json raise @posoco.ModelError {
  match event_json {
    Json::Object(map) =>
      match map.get("response") {
        Some(Json::Object(_) as response) => response
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI SSE parse failure (stage=\{event_stage}.response, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI SSE parse failure (stage=\{event_stage}.response, category=missing)",
          )
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=\{event_stage}, category=not_object)",
      )
  }
}

///|
/// Extract FinishReason from a validated completed response object.
fn extract_finish_from_completed(
  response_json : Json,
) -> @posoco.FinishReason raise @posoco.ModelError {
  let response_obj = match response_json {
    Json::Object(map) => map
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=completed.response, category=not_object)",
      )
  }
  let has_fc = match response_obj.get("output") {
    Some(Json::Array(arr)) => {
      let (_, has_fc) = extract_tool_calls(Json::array(arr))
      has_fc
    }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=completed.output, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=completed.output, category=missing)",
      )
  }
  if has_fc {
    @posoco.FinishReason::ToolCalls
  } else {
    @posoco.FinishReason::Stop
  }
}

///|
fn extract_sse_string_field(
  json : Json,
  field : String,
) -> String raise @posoco.ModelError {
  match json {
    Json::Object(map) =>
      match map.get(field) {
        Some(Json::String(s)) => s
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI SSE parse failure (stage=\{field}, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI SSE parse failure (stage=\{field}, category=missing)",
          )
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=\{field}, category=not_object)",
      )
  }
}

///|
fn extract_sse_int_field(
  json : Json,
  field : String,
) -> Int raise @posoco.ModelError {
  match json {
    Json::Object(map) =>
      match map.get(field) {
        Some(Json::Number(n, ..)) => n.to_int()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI SSE parse failure (stage=\{field}, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI SSE parse failure (stage=\{field}, category=missing)",
          )
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=\{field}, category=not_object)",
      )
  }
}

///|
/// Extract output item info (index, id, name) from output_item.added event.
fn extract_sse_output_item(
  json : Json,
) -> (Int, String, String)? raise @posoco.ModelError {
  match json {
    Json::Object(map) =>
      match map.get("item") {
        Some(Json::Object(item_map)) =>
          match item_map.get("type") {
            Some(Json::String("function_call")) => {
              let idx = extract_sse_int_field(json, "output_index")
              let fc_id = match item_map.get("call_id") {
                Some(Json::String(s)) if s != "" => s
                Some(Json::String(_)) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI SSE parse failure (stage=tool.call_id, category=empty)",
                  )
                Some(_) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI SSE parse failure (stage=tool.call_id, category=wrong_type)",
                  )
                _ =>
                  match item_map.get("id") {
                    Some(Json::String(s)) if s != "" => s
                    Some(Json::String(_)) =>
                      raise @posoco.ModelError::ResponseParse(
                        "OpenAI SSE parse failure (stage=tool.id, category=empty)",
                      )
                    Some(_) =>
                      raise @posoco.ModelError::ResponseParse(
                        "OpenAI SSE parse failure (stage=tool.id, category=wrong_type)",
                      )
                    None =>
                      raise @posoco.ModelError::ResponseParse(
                        "OpenAI SSE parse failure (stage=tool.id, category=missing)",
                      )
                  }
              }
              let fc_name = match item_map.get("name") {
                Some(Json::String(s)) if s != "" => s
                Some(Json::String(_)) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI SSE parse failure (stage=tool.name, category=empty)",
                  )
                Some(_) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI SSE parse failure (stage=tool.name, category=wrong_type)",
                  )
                None =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI SSE parse failure (stage=tool.name, category=missing)",
                  )
              }
              Some((idx, fc_id, fc_name))
            }
            Some(Json::String(_)) => None
            Some(_) =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI SSE parse failure (stage=item.type, category=wrong_type)",
              )
            None =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI SSE parse failure (stage=item.type, category=missing)",
              )
          }
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI SSE parse failure (stage=item, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI SSE parse failure (stage=item, category=missing)",
          )
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI SSE parse failure (stage=event, category=not_object)",
      )
  }
}
