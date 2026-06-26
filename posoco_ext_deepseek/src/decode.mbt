///|
/// Wire decoder: convert DeepSeek API JSON response into posoco types.
///
/// All posoco enum variants are fully qualified (e.g. @posoco.FinishReason::Stop)
/// because MoonBit disambiguates constructors by fully-qualified path in ext
/// packages — bare `Stop` would be unbound.

///|
/// Decode a non-streaming chat completion response.
fn decode_chat_response(json : Json) -> @posoco.ModelResponse raise @posoco.ModelError {
  guard json is Object(root) else {
    raise @posoco.ModelError::Transport("invalid response: not an object")
  }
  // Check for API error
  match root.get("error") {
    Some(err) =>
      match err {
        Object(e) =>
          match e.get("message") {
            Some(String(m)) =>
              raise @posoco.ModelError::Transport("DeepSeek API error: " + m)
            _ => raise @posoco.ModelError::Transport("unknown API error")
          }
        _ => raise @posoco.ModelError::Transport("unknown API error")
      }
    None => ()
  }
  guard root.get("choices") is Some(Array(choices)) else {
    raise @posoco.ModelError::ResponseParse("missing choices in response")
  }
  if choices.length() == 0 {
    raise @posoco.ModelError::ResponseParse("empty choices array")
  }
  guard choices[0] is Object(choice) else {
    raise @posoco.ModelError::ResponseParse("invalid choice entry")
  }
  guard choice.get("message") is Some(Object(msg)) else {
    raise @posoco.ModelError::ResponseParse("missing message in choice")
  }
  // Extract content
  let text = match msg.get("content") {
    Some(String(s)) => s
    _ => ""
  }
  // Extract reasoning_content (DeepSeek reasoner; independent field)
  let reasoning : String? = match msg.get("reasoning_content") {
    Some(String(s)) => if s == "" { None } else { Some(s) }
    _ => None
  }
  // Extract tool calls
  let tool_calls : Array[@posoco.ToolCall] = match msg.get("tool_calls") {
    Some(Array(tcs)) => {
      let result : Array[@posoco.ToolCall] = []
      for tc in tcs {
        match tc {
          Object(o) => {
            let id = match o.get("id") {
              Some(String(s)) => s
              _ => ""
            }
            let (name, args_str) = match o.get("function") {
              Some(Object(f)) => {
                let n = match f.get("name") {
                  Some(String(s)) => s
                  _ => ""
                }
                let a = match f.get("arguments") {
                  Some(String(s)) => s
                  _ => "{}"
                }
                (n, a)
              }
              _ => ("", "{}")
            }
            let args : Json = try @json.parse(args_str) catch {
              _ => Json::object({})
            }
            result.push({ id, name, arguments: args })
          }
          _ => {
            let args : Json = Json::object({})
            result.push({ id: "", name: "", arguments: args })
          }
        }
      }
      result
    }
    _ => []
  }
  // Extract finish reason
  let finish : @posoco.FinishReason = match choice.get("finish_reason") {
    Some(String(s)) =>
      match s {
        "stop" => @posoco.FinishReason::Stop
        "length" => @posoco.FinishReason::Length
        "tool_calls" => @posoco.FinishReason::ToolCalls
        _ => @posoco.FinishReason::Other(s)
      }
    _ => @posoco.FinishReason::Stop
  }
  // Extract usage
  let usage : @posoco.Usage? = match root.get("usage") {
    Some(Object(u)) => {
      let prompt = match u.get("prompt_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      let completion = match u.get("completion_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      let total = match u.get("total_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      Some({ input_tokens: prompt, output_tokens: completion, total_tokens: total })
    }
    _ => None
  }
  // Build posoco Message + ModelResponse
  let content : Array[@posoco.Content] = if text == "" {
    []
  } else {
    [@posoco.Content::Text(text)]
  }
  let message : @posoco.Message = {
    role: @posoco.Role::Assistant,
    content,
    tool_calls,
    tool_call_id: None,
    name: None,
  }
  {
    message,
    tool_calls,
    finish_reason: finish,
    usage,
    reasoning_content: reasoning,
  }
}
