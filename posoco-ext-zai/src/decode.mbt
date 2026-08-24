///|
/// Wire decoder: z.ai chat-completions JSON into kernel Completion.

///|
fn zai_parse_error(stage : String, category : String) -> @posoco.ModelError {
  @posoco.ModelError::ResponseParse(
    "zai response parse failure (stage=\{stage}, category=\{category})",
  )
}

///|
fn decode_chat_response(
  json : Json,
) -> @posoco.Completion raise @posoco.ModelError {
  guard json is Object(root) else {
    raise zai_parse_error("response", "not_object")
  }
  match root.get("error") {
    Some(Object(_)) =>
      raise @posoco.ModelError::Transport(
        "zai API error (stage=response.error, category=structured)",
      )
    Some(_) =>
      raise @posoco.ModelError::Transport(
        "zai API error (stage=response.error, category=wrong_type)",
      )
    None => ()
  }
  let choices = match root.get("choices") {
    Some(Array(choices)) => choices
    Some(_) => raise zai_parse_error("choices", "wrong_type")
    None => raise zai_parse_error("choices", "missing")
  }
  if choices.length() == 0 {
    raise zai_parse_error("choices", "empty")
  }
  guard choices[0] is Object(choice) else {
    raise zai_parse_error("choice", "not_object")
  }
  let msg = match choice.get("message") {
    Some(Object(msg)) => msg
    Some(_) => raise zai_parse_error("message", "wrong_type")
    None => raise zai_parse_error("message", "missing")
  }
  let text = match msg.get("content") {
    Some(String(s)) => s
    Some(Null) | None => ""
    Some(_) => raise zai_parse_error("message.content", "wrong_type")
  }
  let reasoning : String? = match msg.get("reasoning_content") {
    Some(String(s)) => if s == "" { None } else { Some(s) }
    Some(_) => raise zai_parse_error("message.reasoning_content", "wrong_type")
    None => None
  }
  let tool_calls : Array[@posoco.ToolCall] = match msg.get("tool_calls") {
    Some(Array(tcs)) => {
      let result : Array[@posoco.ToolCall] = []
      for tc in tcs {
        guard tc is Object(o) else {
          raise zai_parse_error("tool", "not_object")
        }
        let id = match o.get("id") {
          Some(String(s)) if s != "" => s
          Some(String(_)) => raise zai_parse_error("tool.id", "empty")
          Some(_) => raise zai_parse_error("tool.id", "wrong_type")
          None => raise zai_parse_error("tool.id", "missing")
        }
        let (name, args_str) = match o.get("function") {
          Some(Object(f)) => {
            let n = match f.get("name") {
              Some(String(s)) if s != "" => s
              Some(String(_)) => raise zai_parse_error("tool.name", "empty")
              Some(_) => raise zai_parse_error("tool.name", "wrong_type")
              None => raise zai_parse_error("tool.name", "missing")
            }
            let a = match f.get("arguments") {
              Some(String(s)) => s
              Some(_) => raise zai_parse_error("tool.arguments", "wrong_type")
              None => raise zai_parse_error("tool.arguments", "missing")
            }
            (n, a)
          }
          Some(_) => raise zai_parse_error("tool.function", "wrong_type")
          None => raise zai_parse_error("tool.function", "missing")
        }
        let args : Json = @json.parse(args_str) catch {
          _ =>
            raise zai_parse_error(
              "tool.arguments_json",
              "malformed, payload_chars=\{args_str.length()}",
            )
        }
        result.push({
          call_id: @posoco.CallId::unchecked(id),
          name: @posoco.ToolName::unchecked(name),
          arguments: args,
        })
      }
      result
    }
    Some(_) => raise zai_parse_error("message.tool_calls", "wrong_type")
    None => []
  }
  let finish : @posoco.FinishReason = match choice.get("finish_reason") {
    Some(String("")) => raise zai_parse_error("finish_reason", "empty")
    Some(String(s)) =>
      match s {
        "stop" => @posoco.FinishReason::Stop
        "length" => @posoco.FinishReason::Length
        "tool_calls" => @posoco.FinishReason::ToolCalls
        _ => @posoco.FinishReason::Other(s)
      }
    Some(_) => raise zai_parse_error("finish_reason", "wrong_type")
    None => raise zai_parse_error("finish_reason", "missing")
  }
  let usage : @posoco.Usage? = match root.get("usage") {
    Some(Object(u)) => {
      let input = match u.get("prompt_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      let output = match u.get("completion_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      let total = match u.get("total_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      Some({
        input_tokens: input,
        output_tokens: output,
        total_tokens: total,
        cached_input_tokens: @chatkit.cached_input_tokens_from_usage(u),
        uncached_input_tokens: @chatkit.uncached_input_tokens_from_usage(u),
      })
    }
    Some(_) => raise zai_parse_error("usage", "wrong_type")
    None => None
  }
  let content : Array[@posoco.Content] = if text == "" {
    []
  } else {
    [@posoco.Content::Text(text)]
  }
  let reasoning_val : @posoco.Reasoning? = match reasoning {
    Some(r) => Some(@posoco.Reasoning::{ content: r, raw: None })
    None => None
  }
  @posoco.Completion::Completion(
    content~,
    tool_calls~,
    reasoning=reasoning_val,
    finish_reason=finish,
    usage~,
  )
}
