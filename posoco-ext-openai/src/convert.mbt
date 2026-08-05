///|
/// convert.mbt — Message and tool conversion between posoco and OpenAI formats.
///
/// Shared by chat() and chat_streaming() implementations.

///|
/// Convert a posoco Message to an OpenAI Responses API input item (Json).
pub fn posoco_message_to_openai(msg : @posoco.Message) -> Json {
  match msg {
    UserMessage(content~) =>
      Json::object(
        Map::from_array([
          ("role", Json::string("user")),
          ("content", Json::array(content.map(content_to_openai))),
        ]),
      )
    AssistantMessage(content~, ..) => {
      let fields : Array[(String, Json)] = [("role", Json::string("assistant"))]
      if !content.is_empty() {
        fields.push(("content", Json::array(content.map(content_to_openai))))
      }
      Json::object(Map::from_array(fields))
    }
    ToolMessage(call_id~, outcome~, ..) => {
      let text = outcome_to_wire_text(outcome)
      Json::object(
        Map::from_array([
          ("type", Json::string("function_call_output")),
          ("call_id", Json::string(call_id.to_string())),
          ("output", Json::string(text)),
        ]),
      )
    }
    SystemMessage(content~) =>
      Json::object(
        Map::from_array([
          ("role", Json::string("system")),
          ("content", Json::array(content.map(content_to_openai))),
        ]),
      )
  }
}

///|
fn outcome_to_wire_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    Success(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(message~, ..) => message
    NotExecuted(reason~, ..) => reason.to_string()
  }
}

///|
/// Convert a posoco Content item to OpenAI input content format.
fn content_to_openai(c : @posoco.Content) -> Json {
  match c {
    @posoco.Content::Text(t) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("input_text")),
          ("text", Json::string(t)),
        ]),
      )
    @posoco.Content::Image(media_type~, data~) =>
      Json::object(
        Map::from_array([
          ("type", Json::string("input_image")),
          ("image_url", Json::string("data:\{media_type};base64,\{data}")),
        ]),
      )
  }
}

///|
/// Convert a posoco ToolDef to an OpenAI function tool definition.
pub fn posoco_tool_to_openai(tool : @posoco.ToolDef) -> Json {
  let fields : Array[(String, Json)] = [
    ("type", Json::string("function")),
    ("name", Json::string(tool.name.to_string())),
    ("description", Json::string(tool.description)),
    ("parameters", tool.input_schema),
  ]
  Json::object(Map::from_array(fields))
}

///|
/// Extract tool calls from OpenAI Responses API output array.
/// T07-B: malformed tool-call arguments JSON raises ResponseParse instead
/// of silently becoming {}.
fn extract_tool_calls(
  output : Json,
) -> (Array[@posoco.ToolCall], Bool) raise @posoco.ModelError {
  let items = match output {
    Json::Array(arr) => arr
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=output, category=wrong_type)",
      )
  }
  let tool_calls : Array[@posoco.ToolCall] = []
  let mut has_fc = false
  for item in items {
    match item {
      Json::Object(map) =>
        match map.get("type") {
          Some(Json::String(t)) =>
            if t == "function_call" {
              has_fc = true
              let id = match map.get("call_id") {
                Some(Json::String(s)) if s != "" => s
                Some(Json::String(_)) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=tool.call_id, category=empty)",
                  )
                Some(_) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=tool.call_id, category=wrong_type)",
                  )
                None =>
                  match map.get("id") {
                    Some(Json::String(s)) if s != "" => s
                    Some(Json::String(_)) =>
                      raise @posoco.ModelError::ResponseParse(
                        "OpenAI response parse failure (stage=tool.id, category=empty)",
                      )
                    Some(_) =>
                      raise @posoco.ModelError::ResponseParse(
                        "OpenAI response parse failure (stage=tool.id, category=wrong_type)",
                      )
                    None =>
                      raise @posoco.ModelError::ResponseParse(
                        "OpenAI response parse failure (stage=tool.id, category=missing)",
                      )
                  }
              }
              let name = match map.get("name") {
                Some(Json::String(s)) if s != "" => s
                Some(Json::String(_)) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=tool.name, category=empty)",
                  )
                Some(_) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=tool.name, category=wrong_type)",
                  )
                None =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=tool.name, category=missing)",
                  )
              }
              let args_str = match map.get("arguments") {
                Some(Json::String(s)) => s
                Some(_) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=tool.arguments, category=wrong_type)",
                  )
                None =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=tool.arguments, category=missing)",
                  )
              }
              let args : Json = @json.parse(args_str) catch {
                _ =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{args_str.length()})",
                  )
              }
              tool_calls.push({
                call_id: @posoco.CallId::unchecked(id),
                name: @posoco.ToolName::unchecked(name),
                arguments: args,
              })
            }
          Some(_) =>
            raise @posoco.ModelError::ResponseParse(
              "OpenAI response parse failure (stage=output_item.type, category=wrong_type)",
            )
          None =>
            raise @posoco.ModelError::ResponseParse(
              "OpenAI response parse failure (stage=output_item.type, category=missing)",
            )
        }
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "OpenAI response parse failure (stage=output_item, category=not_object)",
        )
    }
  }
  (tool_calls, has_fc)
}

///|
/// Extract assistant message content from OpenAI Responses API output array.
fn extract_assistant_content(
  output : Json,
) -> Array[@posoco.Content] raise @posoco.ModelError {
  let items = match output {
    Json::Array(arr) => arr
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=output, category=wrong_type)",
      )
  }
  let content : Array[@posoco.Content] = []
  for item in items {
    match item {
      Json::Object(map) =>
        match map.get("type") {
          Some(Json::String(t)) =>
            if t == "message" {
              match map.get("content") {
                Some(Json::Array(content_items)) =>
                  for ci in content_items {
                    match ci {
                      Json::Object(ci_map) =>
                        match ci_map.get("type") {
                          Some(Json::String("output_text")) =>
                            match ci_map.get("text") {
                              Some(Json::String(s)) =>
                                content.push(@posoco.Content::Text(s))
                              Some(_) =>
                                raise @posoco.ModelError::ResponseParse(
                                  "OpenAI response parse failure (stage=message.output_text.text, category=wrong_type)",
                                )
                              None =>
                                raise @posoco.ModelError::ResponseParse(
                                  "OpenAI response parse failure (stage=message.output_text.text, category=missing)",
                                )
                            }
                          Some(Json::String(_)) => ()
                          Some(_) =>
                            raise @posoco.ModelError::ResponseParse(
                              "OpenAI response parse failure (stage=message.content_item.type, category=wrong_type)",
                            )
                          None =>
                            raise @posoco.ModelError::ResponseParse(
                              "OpenAI response parse failure (stage=message.content_item.type, category=missing)",
                            )
                        }
                      _ =>
                        raise @posoco.ModelError::ResponseParse(
                          "OpenAI response parse failure (stage=message.content_item, category=not_object)",
                        )
                    }
                  }
                Some(_) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=message.content, category=wrong_type)",
                  )
                None =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=message.content, category=missing)",
                  )
              }
            }
          Some(_) =>
            raise @posoco.ModelError::ResponseParse(
              "OpenAI response parse failure (stage=output_item.type, category=wrong_type)",
            )
          None =>
            raise @posoco.ModelError::ResponseParse(
              "OpenAI response parse failure (stage=output_item.type, category=missing)",
            )
        }
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "OpenAI response parse failure (stage=output_item, category=not_object)",
        )
    }
  }
  content
}

///|
/// Extract usage from OpenAI Responses API response.
fn extract_usage(resp : Json) -> @posoco.Usage? raise @posoco.ModelError {
  match resp {
    Json::Object(map) =>
      match map.get("usage") {
        Some(Json::Object(usage_map)) => {
          let input_tokens = match usage_map.get("input_tokens") {
            Some(Json::Number(n, ..)) => Some(n.to_int())
            Some(_) =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI response parse failure (stage=usage.input_tokens, category=wrong_type)",
              )
            None =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI response parse failure (stage=usage.input_tokens, category=missing)",
              )
          }
          let output_tokens = match usage_map.get("output_tokens") {
            Some(Json::Number(n, ..)) => Some(n.to_int())
            Some(_) =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI response parse failure (stage=usage.output_tokens, category=wrong_type)",
              )
            None =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI response parse failure (stage=usage.output_tokens, category=missing)",
              )
          }
          let total_tokens = match usage_map.get("total_tokens") {
            Some(Json::Number(n, ..)) => Some(n.to_int())
            Some(_) =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI response parse failure (stage=usage.total_tokens, category=wrong_type)",
              )
            None =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI response parse failure (stage=usage.total_tokens, category=missing)",
              )
          }
          Some(@posoco.Usage::{ input_tokens, output_tokens, total_tokens })
        }
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI response parse failure (stage=usage, category=wrong_type)",
          )
        None => None
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=response, category=not_object)",
      )
  }
}

///|
/// Validate a terminal Responses API object without serializing provider error
/// bodies or status payloads. Only `completed` is a successful response.
fn validate_openai_terminal_response(
  resp : Json,
  stage_prefix : String,
) -> Unit raise @posoco.ModelError {
  let map = match resp {
    Json::Object(map) => map
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=response, category=not_object)",
      )
  }
  match map.get("error") {
    Some(Json::Null) | None => ()
    Some(Json::Object(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response terminal failure (stage=\{stage_prefix}error, category=provider_error)",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=\{stage_prefix}error, category=wrong_type)",
      )
  }
  match map.get("status") {
    Some(Json::String("completed")) => ()
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response terminal failure (stage=\{stage_prefix}status, category=not_completed)",
      )
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=\{stage_prefix}status, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=\{stage_prefix}status, category=missing)",
      )
  }
}

///|
/// Parse a complete OpenAI Responses API response into a posoco Completion.
pub fn parse_openai_response(
  resp_json : Json,
) -> @posoco.Completion raise @posoco.ModelError {
  validate_openai_terminal_response(resp_json, "")
  let output = match resp_json {
    Json::Object(map) =>
      match map.get("output") {
        Some(Json::Array(_) as output) => output
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI response parse failure (stage=output, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI response parse failure (stage=output, category=missing)",
          )
      }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=response, category=not_object)",
      )
  }
  let (tool_calls, has_fc) = extract_tool_calls(output)
  let content = extract_assistant_content(output)
  let usage = extract_usage(resp_json)
  let finish_reason = if has_fc {
    @posoco.FinishReason::ToolCalls
  } else {
    @posoco.FinishReason::Stop
  }
  @posoco.Completion::Completion(
    content~,
    tool_calls~,
    reasoning=None,
    finish_reason~,
    usage~,
  )
}
