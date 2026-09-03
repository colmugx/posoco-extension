///|
/// convert.mbt — Message and tool conversion between posoco and OpenAI formats.
///
/// Shared by chat() and chat_streaming() implementations.

///|
/// Convert a posoco Message to OpenAI Responses API input item(s) (Json).
///
/// One canonical message can map to MULTIPLE input items: the Responses API
/// represents an assistant turn as distinct `reasoning` / `message` /
/// `function_call` items, and the official manual context-management guidance
/// is to pass every output item back untouched — "dropping reasoning,
/// function call, or function call output items" is a named common migration
/// error (migrate-to-responses guide). An AssistantMessage therefore expands
/// to: reasoning items (verbatim replay from `Reasoning.raw`), then a
/// `message` item (only when it carries visible content), then one
/// `function_call` item per tool call (correlated with its
/// `function_call_output` via `call_id`).
pub fn posoco_message_to_openai_items(msg : @posoco.Message) -> Array[Json] {
  match msg {
    UserMessage(content~) =>
      [
        Json::object(
          Map::from_array([
            ("role", Json::string("user")),
            ("content", Json::array(content.map(content_to_openai))),
          ]),
        ),
      ]
    AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) => {
      let _ = finish_reason
      let items : Array[Json] = []
      // Reasoning items first, replayed verbatim (they preceded the visible
      // output in the original response). The API keeps them opaque; only
      // the raw item payload can be replayed, never a re-serialization.
      match reasoning {
        Some(r) =>
          match r.raw {
            Some(Json::Array(raw_items)) =>
              for item in raw_items {
                items.push(item)
              }
            Some(_) | None => ()
          }
        None => ()
      }
      if !content.is_empty() {
        let fields : Array[(String, Json)] = [
          ("role", Json::string("assistant")),
        ]
        fields.push(("content", Json::array(content.map(content_to_openai))))
        items.push(Json::object(Map::from_array(fields)))
      }
      // function_call items: the previous turn's tool calls must be passed
      // back alongside their outputs, or the model loses the call context.
      for tc in tool_calls {
        items.push(
          Json::object(
            Map::from_array([
              ("type", Json::string("function_call")),
              ("call_id", Json::string(tc.call_id.to_string())),
              ("name", Json::string(tc.name.to_string())),
              ("arguments", Json::string(tc.arguments.stringify())),
            ]),
          ),
        )
      }
      // Defensive: an empty assistant turn keeps the legacy bare item rather
      // than vanishing from the input array.
      if items.is_empty() {
        let fields : Array[(String, Json)] = [
          ("role", Json::string("assistant")),
        ]
        items.push(Json::object(Map::from_array(fields)))
      }
      items
    }
    ToolMessage(call_id~, outcome~, ..) => {
      let text = outcome_to_wire_text(outcome)
      [
        Json::object(
          Map::from_array([
            ("type", Json::string("function_call_output")),
            ("call_id", Json::string(call_id.to_string())),
            ("output", Json::string(text)),
          ]),
        ),
      ]
    }
    SystemMessage(content~) =>
      [
        Json::object(
          Map::from_array([
            ("role", Json::string("system")),
            ("content", Json::array(content.map(content_to_openai))),
          ]),
        ),
      ]
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
/// Parse one `function_call` output item into a canonical ToolCall.
/// `call_id` falls back to the item `id` when null (explicit-null tolerance
/// aligned with the streaming path). T07-B: malformed tool-call arguments
/// JSON raises ResponseParse instead of silently becoming {}.
fn parse_function_call_item(
  map : Map[String, Json],
) -> @posoco.ToolCall raise @posoco.ModelError {
  let id = match map.get("call_id") {
    Some(Json::String(s)) if s != "" => s
    Some(Json::String(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=tool.call_id, category=empty)",
      )
    Some(Json::Null) =>
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
  {
    call_id: @posoco.CallId::unchecked(id),
    name: @posoco.ToolName::unchecked(name),
    arguments: args,
  }
}

///|
/// Extract tool calls from OpenAI Responses API output array.
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
              tool_calls.push(parse_function_call_item(map))
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
                // Explicit "content": null carries no items; skip it. A
                // missing content key stays loud below.
                Some(Json::Null) => ()
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
/// Extract usage from OpenAI Responses API response. "usage": null = absent
/// (returns None); inside a usage object, missing token fields map to None
/// instead of failing (aligned with the chat-completions tolerance); wrong
/// types stay loud.
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
            None => None
          }
          let output_tokens = match usage_map.get("output_tokens") {
            Some(Json::Number(n, ..)) => Some(n.to_int())
            Some(_) =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI response parse failure (stage=usage.output_tokens, category=wrong_type)",
              )
            None => None
          }
          let total_tokens = match usage_map.get("total_tokens") {
            Some(Json::Number(n, ..)) => Some(n.to_int())
            Some(_) =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI response parse failure (stage=usage.total_tokens, category=wrong_type)",
              )
            None => None
          }
          let cached_input_tokens = match
            usage_map.get("input_tokens_details") {
            Some(Json::Object(details)) =>
              match details.get("cached_tokens") {
                Some(Json::Number(n, ..)) => Some(n.to_int())
                Some(Json::Null) | None => None
                Some(_) =>
                  raise @posoco.ModelError::ResponseParse(
                    "OpenAI response parse failure (stage=usage.input_tokens_details.cached_tokens, category=wrong_type)",
                  )
              }
            Some(Json::Null) | None => None
            Some(_) =>
              raise @posoco.ModelError::ResponseParse(
                "OpenAI response parse failure (stage=usage.input_tokens_details, category=wrong_type)",
              )
          }
          Some(@posoco.Usage::{
            input_tokens,
            output_tokens,
            total_tokens,
            cached_input_tokens,
            uncached_input_tokens: None,
          })
        }
        Some(Json::Null) | None => None
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI response parse failure (stage=usage, category=wrong_type)",
          )
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
/// Collect reasoning items from a Responses API output array for verbatim
/// replay, plus the concatenated summary text (empty when summaries were not
/// requested). Reasoning items are opaque — the API does not return raw
/// reasoning text — so the whole item payload must be preserved for the next
/// request (official reasoning guide: "pass back all reasoning items").
fn extract_reasoning_items(
  output : Json,
) -> (Array[Json], String) raise @posoco.ModelError {
  let items = match output {
    Json::Array(arr) => arr
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI response parse failure (stage=output, category=wrong_type)",
      )
  }
  let raw : Array[Json] = []
  let summary = StringBuilder()
  for item in items {
    match item {
      Json::Object(map) =>
        match map.get("type") {
          Some(Json::String("reasoning")) => {
            raw.push(item)
            match map.get("summary") {
              Some(Json::Array(parts)) =>
                for part in parts {
                  match part {
                    Json::Object(pmap) =>
                      match (pmap.get("type"), pmap.get("text")) {
                        (
                          Some(Json::String("summary_text")),
                          Some(Json::String(t)),
                        ) => summary.write_string(t)
                        _ => ()
                      }
                    _ => ()
                  }
                }
              _ => ()
            }
          }
          _ => ()
        }
      _ => ()
    }
  }
  (raw, summary.to_string())
}

///|
/// Extract the visible text of a message item's content. Accepts the plain
/// string shorthand and typed text parts (`output_text` / `input_text` /
/// `text`); non-text parts are skipped.
fn message_item_text(
  map : Map[String, Json],
) -> String raise @posoco.ModelError {
  match map.get("content") {
    Some(Json::String(s)) => s
    Some(Json::Array(parts)) => {
      let b = StringBuilder()
      for part in parts {
        match part {
          Json::Object(pmap) =>
            match pmap.get("type") {
              Some(Json::String(t)) =>
                if t == "output_text" || t == "input_text" || t == "text" {
                  match pmap.get("text") {
                    Some(Json::String(s)) => b.write_string(s)
                    _ => ()
                  }
                }
              _ => ()
            }
          _ => ()
        }
      }
      b.to_string()
    }
    Some(Json::Null) | None => ""
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI compact parse failure (stage=message.content, category=wrong_type)",
      )
  }
}

///|
/// Decode Responses API items back into canonical messages. Used for
/// `/responses/compact` output, which is the canonical next context window
/// ("pass it into your next /responses call as-is — do not prune").
///
/// Opaque state items (`reasoning`, `compaction`, and any item type canonical
/// messages cannot represent, e.g. hosted-tool items) ride on the NEXT
/// assistant message's `Reasoning.raw` so they replay verbatim on later
/// requests; a run of state/function_call items with no following assistant
/// message flushes as an empty-content assistant message, preserving the
/// original wire order exactly.
fn openai_items_to_posoco_messages(
  output : Json,
) -> Array[@posoco.Message] raise @posoco.ModelError {
  let items = match output {
    Json::Array(arr) => arr
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI compact parse failure (stage=output, category=wrong_type)",
      )
  }
  let messages : Array[@posoco.Message] = []
  let pending_state : Array[Json] = []
  let pending_calls : Array[@posoco.ToolCall] = []
  let take_reasoning = fn() -> @posoco.Reasoning? {
    if pending_state.is_empty() {
      None
    } else {
      let raw = Some(Json::array(pending_state.copy()))
      pending_state.clear()
      Some(@posoco.Reasoning::{ content: "", raw, })
    }
  }
  let take_calls = fn() -> Array[@posoco.ToolCall] {
    let calls = pending_calls.copy()
    pending_calls.clear()
    calls
  }
  let flush_empty_assistant = fn() -> Unit {
    if !pending_state.is_empty() || !pending_calls.is_empty() {
      let reasoning = take_reasoning()
      let tool_calls = take_calls()
      let finish_reason = if tool_calls.is_empty() {
        @posoco.FinishReason::Stop
      } else {
        @posoco.FinishReason::ToolCalls
      }
      messages.push(
        @posoco.Message::AssistantMessage(
          content=[],
          tool_calls~,
          reasoning~,
          finish_reason~,
        ),
      )
    }
  }
  for item in items {
    match item {
      Json::Object(map) => {
        let item_type = match map.get("type") {
          Some(Json::String(t)) => t
          _ => ""
        }
        let role = match map.get("role") {
          Some(Json::String(r)) => r
          _ => ""
        }
        // Untyped items with a role are message shorthand ({role, content}).
        let kind = if item_type != "" {
          item_type
        } else if role != "" {
          "message"
        } else {
          ""
        }
        match kind {
          "function_call" => pending_calls.push(parse_function_call_item(map))
          "function_call_output" => {
            flush_empty_assistant()
            let call_id = match map.get("call_id") {
              Some(Json::String(s)) if s != "" => s
              _ =>
                raise @posoco.ModelError::ResponseParse(
                  "OpenAI compact parse failure (stage=tool.call_id, category=missing)",
                )
            }
            let text = match map.get("output") {
              Some(Json::String(s)) => s
              Some(_) =>
                raise @posoco.ModelError::ResponseParse(
                  "OpenAI compact parse failure (stage=tool.output, category=wrong_type)",
                )
              None => ""
            }
            messages.push(
              @posoco.Message::ToolMessage(
                call_id=@posoco.CallId::unchecked(call_id),
                // The output item does not name the tool; the name is not
                // re-encoded on the wire, so an empty placeholder is kept.
                tool_name=@posoco.ToolName::unchecked(""),
                outcome=@posoco.ToolOutcome::Success(
                  content=text,
                  structured=None,
                ),
              ),
            )
          }
          "message" => {
            let text = message_item_text(map)
            match role {
              "assistant" => {
                let reasoning = take_reasoning()
                let tool_calls = take_calls()
                let finish_reason = if tool_calls.is_empty() {
                  @posoco.FinishReason::Stop
                } else {
                  @posoco.FinishReason::ToolCalls
                }
                let content : Array[@posoco.Content] = if text == "" {
                  []
                } else {
                  [@posoco.Content::Text(text)]
                }
                messages.push(
                  @posoco.Message::AssistantMessage(
                    content~,
                    tool_calls~,
                    reasoning~,
                    finish_reason~,
                  ),
                )
              }
              "user" => {
                flush_empty_assistant()
                messages.push(
                  @posoco.Message::UserMessage(content=[
                    @posoco.Content::Text(text),
                  ]),
                )
              }
              "system" | "developer" => {
                flush_empty_assistant()
                messages.push(
                  @posoco.Message::SystemMessage(content=[
                    @posoco.Content::Text(text),
                  ]),
                )
              }
              _ =>
                raise @posoco.ModelError::ResponseParse(
                  "OpenAI compact parse failure (stage=message.role, category=unknown)",
                )
            }
          }
          // reasoning / compaction / anything canonical cannot represent:
          // keep the raw item for verbatim replay on the next assistant.
          _ => pending_state.push(item)
        }
      }
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "OpenAI compact parse failure (stage=output_item, category=not_object)",
        )
    }
  }
  flush_empty_assistant()
  messages
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
        Some(Json::Null) | None =>
          // A missing or explicit-null output carries no content or tool
          // calls; treat it as an empty array (FinishReason::Stop).
          Json::array([])
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "OpenAI response parse failure (stage=output, category=wrong_type)",
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
  let (raw_reasoning, summary) = extract_reasoning_items(output)
  let reasoning : @posoco.Reasoning? = if raw_reasoning.is_empty() {
    None
  } else {
    Some(@posoco.Reasoning::{
      content: summary,
      raw: Some(Json::array(raw_reasoning)),
    })
  }
  let finish_reason = if has_fc {
    @posoco.FinishReason::ToolCalls
  } else {
    @posoco.FinishReason::Stop
  }
  @posoco.Completion::Completion(
    content~,
    tool_calls~,
    reasoning~,
    finish_reason~,
    usage~,
  )
}
