///|
/// SSE streaming for DeepSeek chat completions.
///
/// DeepSeek SSE event format (different from OpenAI Responses API):
///   data: {"choices":[{"delta":{"content":"..."},"finish_reason":null}]}
///   data: {"choices":[{"delta":{"reasoning_content":"..."},"finish_reason":null}]}
///   data: {"choices":[{"delta":{"tool_calls":[...]}}]}
///   data: {"choices":[{"finish_reason":"stop"}],"usage":{...}}
///   data: [DONE]

///|
/// Parse one SSE data line into StreamChunk(s) and feed to accumulator.
/// Returns true when the stream is finished ([DONE] or finish_reason present).
fn process_deepseek_sse(
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> Bool {
  // [DONE] marker — end of stream
  if data == "[DONE]" {
    let chunk = @posoco.StreamChunk::Finish(reason=@posoco.FinishReason::Stop)
    on_chunk(chunk)
    acc.push(chunk)
    return true
  }
  let event_json : Json = try @json.parse(data) catch {
    _ => return false
  }
  guard event_json is Object(root) else {
    return false
  }
  guard root.get("choices") is Some(Array(choices)) else {
    // May be a usage-only chunk
    match root.get("usage") {
      Some(_) => {
        let usage = extract_usage(root)
        let chunk = @posoco.StreamChunk::Usage(usage)
        on_chunk(chunk)
        acc.push(chunk)
      }
      None => ()
    }
    return false
  }
  if choices.length() == 0 {
    return false
  }
  guard choices[0] is Object(choice) else {
    return false
  }
  // Check finish_reason first
  match choice.get("finish_reason") {
    Some(String(reason)) =>
      if reason != "" && reason != "null" {
        let fr = match reason {
          "stop" => @posoco.FinishReason::Stop
          "length" => @posoco.FinishReason::Length
          "tool_calls" => @posoco.FinishReason::ToolCalls
          _ => @posoco.FinishReason::Other(reason)
        }
        // Extract usage if present on the finish chunk
        match root.get("usage") {
          Some(_) => {
            let usage = extract_usage(root)
            let usage_chunk = @posoco.StreamChunk::Usage(usage)
            on_chunk(usage_chunk)
            acc.push(usage_chunk)
          }
          None => ()
        }
        let chunk = @posoco.StreamChunk::Finish(reason=fr)
        on_chunk(chunk)
        acc.push(chunk)
        return true
      }
    _ => ()
  }
  // Process delta
  match choice.get("delta") {
    Some(Object(delta)) => {
      // Text content delta
      match delta.get("content") {
        Some(String(token)) => {
          let chunk = @posoco.StreamChunk::TextDelta(token~)
          on_chunk(chunk)
          acc.push(chunk)
        }
        _ => ()
      }
      // Reasoning content delta (deepseek-reasoner)
      match delta.get("reasoning_content") {
        Some(String(token)) => {
          let chunk = @posoco.StreamChunk::ReasoningDelta(token~)
          on_chunk(chunk)
          acc.push(chunk)
        }
        _ => ()
      }
      // Tool call deltas
      match delta.get("tool_calls") {
        Some(Array(tcs)) =>
          for tc in tcs {
            match tc {
              Object(o) => {
                let idx = match o.get("index") {
                  Some(Number(n, ..)) => n.to_int()
                  _ => 0
                }
                let id : String? = match o.get("id") {
                  Some(String(s)) => Some(s)
                  _ => None
                }
                let (name, args_delta) : (String?, String?) = match o.get(
                  "function",
                ) {
                  Some(Object(f)) => {
                    let n : String? = match f.get("name") {
                      Some(String(s)) => Some(s)
                      _ => None
                    }
                    let a : String? = match f.get("arguments") {
                      Some(String(s)) => Some(s)
                      _ => None
                    }
                    (n, a)
                  }
                  _ => (None, None)
                }
                let chunk = @posoco.StreamChunk::ToolCallDelta(
                  index=idx,
                  id~,
                  name~,
                  arguments_delta=args_delta,
                )
                on_chunk(chunk)
                acc.push(chunk)
              }
              _ => ()
            }
          }
        _ => ()
      }
    }
    _ => ()
  }
  false
}

///|
/// Extract Usage from a JSON object containing usage fields.
fn extract_usage(root : Map[String, Json]) -> @posoco.Usage {
  match root.get("usage") {
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
      { input_tokens: prompt, output_tokens: completion, total_tokens: total }
    }
    _ => {
      let null_usage : @posoco.Usage = {
        input_tokens: None,
        output_tokens: None,
        total_tokens: None,
      }
      null_usage
    }
  }
}
