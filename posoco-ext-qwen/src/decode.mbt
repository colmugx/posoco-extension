///|
fn qwen_parse_error(stage : String, category : String) -> @posoco.ModelError {
  @posoco.ModelError::ResponseParse(
    "qwen response parse failure (stage=\{stage}, category=\{category})",
  )
}

///|
fn decode_chat_response(
  json : Json,
) -> @posoco.Completion raise @posoco.ModelError {
  guard json is Object(root) else {
    raise qwen_parse_error("response", "not_object")
  }
  match root.get("error") {
    Some(Object(_)) =>
      raise @posoco.ModelError::Transport(
        "qwen API error (stage=response.error, category=structured)",
      )
    Some(_) =>
      raise @posoco.ModelError::Transport(
        "qwen API error (stage=response.error, category=wrong_type)",
      )
    None => ()
  }
  let choices = match root.get("choices") {
    Some(Array(values)) => values
    Some(_) => raise qwen_parse_error("choices", "wrong_type")
    None => raise qwen_parse_error("choices", "missing")
  }
  if choices.length() == 0 {
    raise qwen_parse_error("choices", "empty")
  }
  guard choices[0] is Object(choice) else {
    raise qwen_parse_error("choice", "not_object")
  }
  let message = match choice.get("message") {
    Some(Object(value)) => value
    Some(_) => raise qwen_parse_error("message", "wrong_type")
    None => raise qwen_parse_error("message", "missing")
  }
  let text = match message.get("content") {
    Some(String(value)) => value
    Some(Null) | None => ""
    Some(_) => raise qwen_parse_error("message.content", "wrong_type")
  }
  let reasoning : String? = match message.get("reasoning_content") {
    Some(String(value)) => if value == "" { None } else { Some(value) }
    Some(Null) | None => None
    Some(_) => raise qwen_parse_error("message.reasoning_content", "wrong_type")
  }
  let tool_calls : Array[@posoco.ToolCall] = match message.get("tool_calls") {
    Some(Array(values)) => {
      let result : Array[@posoco.ToolCall] = []
      for value in values {
        guard value is Object(call) else {
          raise qwen_parse_error("tool", "not_object")
        }
        let id = match call.get("id") {
          Some(String(value)) if value != "" => value
          Some(String(_)) => raise qwen_parse_error("tool.id", "empty")
          Some(_) => raise qwen_parse_error("tool.id", "wrong_type")
          None => raise qwen_parse_error("tool.id", "missing")
        }
        let (name, arguments) = match call.get("function") {
          Some(Object(function)) => {
            let name = match function.get("name") {
              Some(String(value)) if value != "" => value
              Some(String(_)) => raise qwen_parse_error("tool.name", "empty")
              Some(_) => raise qwen_parse_error("tool.name", "wrong_type")
              None => raise qwen_parse_error("tool.name", "missing")
            }
            let arguments = match function.get("arguments") {
              Some(String(value)) => value
              Some(_) => raise qwen_parse_error("tool.arguments", "wrong_type")
              None => raise qwen_parse_error("tool.arguments", "missing")
            }
            (name, arguments)
          }
          Some(_) => raise qwen_parse_error("tool.function", "wrong_type")
          None => raise qwen_parse_error("tool.function", "missing")
        }
        let parsed : Json = @json.parse(arguments) catch {
          _ =>
            raise qwen_parse_error(
              "tool.arguments_json",
              "malformed, payload_chars=\{arguments.length()}",
            )
        }
        result.push({
          call_id: @posoco.CallId::unchecked(id),
          name: @posoco.ToolName::unchecked(name),
          arguments: parsed,
        })
      }
      result
    }
    Some(Null) | None => []
    Some(_) => raise qwen_parse_error("message.tool_calls", "wrong_type")
  }
  let finish_reason : @posoco.FinishReason = match choice.get("finish_reason") {
    Some(String("")) => raise qwen_parse_error("finish_reason", "empty")
    Some(String(value)) =>
      match value {
        "stop" => @posoco.FinishReason::Stop
        "length" => @posoco.FinishReason::Length
        "tool_calls" => @posoco.FinishReason::ToolCalls
        _ => @posoco.FinishReason::Other(value)
      }
    Some(_) => raise qwen_parse_error("finish_reason", "wrong_type")
    None => raise qwen_parse_error("finish_reason", "missing")
  }
  let usage : @posoco.Usage? = match root.get("usage") {
    Some(Object(value)) => {
      let input = match value.get("prompt_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      let output = match value.get("completion_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      let total = match value.get("total_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      Some({
        input_tokens: input,
        output_tokens: output,
        total_tokens: total,
        cached_input_tokens: @chatkit.cached_input_tokens_from_usage(value),
        uncached_input_tokens: @chatkit.uncached_input_tokens_from_usage(value),
      })
    }
    Some(Null) | None => None
    Some(_) => raise qwen_parse_error("usage", "wrong_type")
  }
  let content : Array[@posoco.Content] = if text == "" {
    []
  } else {
    [@posoco.Content::Text(text)]
  }
  let reasoning_value : @posoco.Reasoning? = match reasoning {
    Some(value) => Some(@posoco.Reasoning::{ content: value, raw: None, })
    None => None
  }
  @posoco.Completion::Completion(
    content~,
    tool_calls~,
    reasoning=reasoning_value,
    finish_reason~,
    usage~,
  )
}
