///|
/// Wire decoder: convert DeepSeek API JSON response into kernel Completion.

///|
/// Decode a non-streaming chat completion response into a Completion.
fn decode_chat_response(
  json : Json,
) -> @posoco.Completion raise @posoco.ModelError {
  guard json is Object(root) else {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek response parse failure (stage=response, category=not_object)",
    )
  }
  match root.get("error") {
    Some(Object(_)) =>
      raise @posoco.ModelError::Transport(
        "DeepSeek API error (stage=response.error, category=structured)",
      )
    Some(_) =>
      raise @posoco.ModelError::Transport(
        "DeepSeek API error (stage=response.error, category=wrong_type)",
      )
    None => ()
  }
  let choices = match root.get("choices") {
    Some(Array(choices)) => choices
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=choices, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=choices, category=missing)",
      )
  }
  if choices.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek response parse failure (stage=choices, category=empty)",
    )
  }
  guard choices[0] is Object(choice) else {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek response parse failure (stage=choice, category=not_object)",
    )
  }
  let msg = match choice.get("message") {
    Some(Object(msg)) => msg
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=message, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=message, category=missing)",
      )
  }
  let text = match msg.get("content") {
    Some(String(s)) => s
    Some(Null) | None => ""
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=message.content, category=wrong_type)",
      )
  }
  // reasoning_content: DeepSeek reasoner field, independent of content.
  let reasoning : String? = match msg.get("reasoning_content") {
    Some(String(s)) => if s == "" { None } else { Some(s) }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=message.reasoning_content, category=wrong_type)",
      )
    None => None
  }
  let tool_calls : Array[@posoco.ToolCall] = match msg.get("tool_calls") {
    Some(Array(tcs)) => {
      let result : Array[@posoco.ToolCall] = []
      for tc in tcs {
        match tc {
          Object(o) => {
            let id = match o.get("id") {
              Some(String(s)) if s != "" => s
              Some(String(_)) =>
                raise @posoco.ModelError::ResponseParse(
                  "DeepSeek response parse failure (stage=tool.id, category=empty)",
                )
              Some(_) =>
                raise @posoco.ModelError::ResponseParse(
                  "DeepSeek response parse failure (stage=tool.id, category=wrong_type)",
                )
              None =>
                raise @posoco.ModelError::ResponseParse(
                  "DeepSeek response parse failure (stage=tool.id, category=missing)",
                )
            }
            let (name, args_str) = match o.get("function") {
              Some(Object(f)) => {
                let n = match f.get("name") {
                  Some(String(s)) if s != "" => s
                  Some(String(_)) =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek response parse failure (stage=tool.name, category=empty)",
                    )
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek response parse failure (stage=tool.name, category=wrong_type)",
                    )
                  None =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek response parse failure (stage=tool.name, category=missing)",
                    )
                }
                let a = match f.get("arguments") {
                  Some(String(s)) => s
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek response parse failure (stage=tool.arguments, category=wrong_type)",
                    )
                  None =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek response parse failure (stage=tool.arguments, category=missing)",
                    )
                }
                (n, a)
              }
              Some(_) =>
                raise @posoco.ModelError::ResponseParse(
                  "DeepSeek response parse failure (stage=tool.function, category=wrong_type)",
                )
              None =>
                raise @posoco.ModelError::ResponseParse(
                  "DeepSeek response parse failure (stage=tool.function, category=missing)",
                )
            }
            let args : Json = @json.parse(args_str) catch {
              _ =>
                raise @posoco.ModelError::ResponseParse(
                  "DeepSeek response parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{args_str.length()})",
                )
            }
            result.push({
              call_id: @posoco.CallId::unchecked(id),
              name: @posoco.ToolName::unchecked(name),
              arguments: args,
            })
          }
          _ =>
            raise @posoco.ModelError::ResponseParse(
              "DeepSeek response parse failure (stage=tool, category=not_object)",
            )
        }
      }
      result
    }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=message.tool_calls, category=wrong_type)",
      )
    None => []
  }
  let finish : @posoco.FinishReason = match choice.get("finish_reason") {
    Some(String("")) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=finish_reason, category=empty)",
      )
    Some(String(s)) =>
      match s {
        "stop" => @posoco.FinishReason::Stop
        "length" => @posoco.FinishReason::Length
        "tool_calls" => @posoco.FinishReason::ToolCalls
        _ => @posoco.FinishReason::Other(s)
      }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=finish_reason, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=finish_reason, category=missing)",
      )
  }
  let usage : @posoco.Usage? = match root.get("usage") {
    Some(Object(_)) => Some(extract_usage(root))
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek response parse failure (stage=usage, category=wrong_type)",
      )
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

///|
/// Extract Usage from a JSON object containing usage fields.
fn extract_usage(
  root : Map[String, Json],
) -> @posoco.Usage raise @posoco.ModelError {
  match root.get("usage") {
    Some(Object(u)) => {
      let prompt = match u.get("prompt_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=usage.prompt_tokens, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=usage.prompt_tokens, category=missing)",
          )
      }
      let completion = match u.get("completion_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=usage.completion_tokens, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=usage.completion_tokens, category=missing)",
          )
      }
      let total = match u.get("total_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=usage.total_tokens, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=usage.total_tokens, category=missing)",
          )
      }
      {
        input_tokens: prompt,
        output_tokens: completion,
        total_tokens: total,
        cached_input_tokens: @chatkit.cached_input_tokens_from_usage(u),
      }
    }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=usage, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=usage, category=missing)",
      )
  }
}
