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
) -> Bool raise @posoco.ModelError {
  // [DONE] marker — end of stream
  if data == "[DONE]" {
    let chunk = @posoco.StreamChunk::Finish(reason=@posoco.FinishReason::Stop)
    on_chunk(chunk)
    acc.push(chunk)
    return true
  }
  let event_json : Json = @json.parse(data) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=json, payload_chars=\{data.length()})",
      )
  }
  guard event_json is Object(root) else {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek SSE parse failure (stage=event, category=not_object)",
    )
  }
  let choices = match root.get("choices") {
    Some(Array(choices)) => choices
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=choices, category=wrong_type)",
      )
    None => {
      // A usage-only chunk is valid without choices.
      match root.get("usage") {
        Some(Object(_)) => {
          let usage = extract_usage(root)
          let chunk = @posoco.StreamChunk::Usage(usage)
          on_chunk(chunk)
          acc.push(chunk)
        }
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=usage, category=wrong_type)",
          )
        None =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=choices, category=missing)",
          )
      }
      return false
    }
  }
  if choices.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek SSE parse failure (stage=choices, category=empty)",
    )
  }
  guard choices[0] is Object(choice) else {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek SSE parse failure (stage=choice, category=not_object)",
    )
  }
  // Check finish_reason first
  match choice.get("finish_reason") {
    Some(String(reason)) =>
      if reason != "" {
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
      } else {
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek SSE parse failure (stage=finish_reason, category=empty)",
        )
      }
    Some(Null) | None => ()
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=finish_reason, category=wrong_type)",
      )
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
        Some(Null) | None => ()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=delta.content, category=wrong_type)",
          )
      }
      // Reasoning content delta (deepseek-reasoner)
      match delta.get("reasoning_content") {
        Some(String(token)) => {
          let chunk = @posoco.StreamChunk::ReasoningDelta(token~)
          on_chunk(chunk)
          acc.push(chunk)
        }
        Some(Null) | None => ()
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=delta.reasoning_content, category=wrong_type)",
          )
      }
      // Tool call deltas
      match delta.get("tool_calls") {
        Some(Array(tcs)) =>
          for tc in tcs {
            match tc {
              Object(o) => {
                let idx = match o.get("index") {
                  Some(Number(n, ..)) if n.to_int() >= 0 => n.to_int()
                  Some(Number(_, ..)) =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek SSE parse failure (stage=tool.index, category=negative)",
                    )
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek SSE parse failure (stage=tool.index, category=wrong_type)",
                    )
                  None =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek SSE parse failure (stage=tool.index, category=missing)",
                    )
                }
                let id : String? = match o.get("id") {
                  Some(String(s)) if s != "" => Some(s)
                  Some(String(_)) =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek SSE parse failure (stage=tool.id, category=empty)",
                    )
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek SSE parse failure (stage=tool.id, category=wrong_type)",
                    )
                  None => None
                }
                let (name, args_delta) : (String?, String?) = match
                  o.get("function") {
                  Some(Object(f)) => {
                    let n : String? = match f.get("name") {
                      Some(String(s)) if s != "" => Some(s)
                      Some(String(_)) =>
                        raise @posoco.ModelError::ResponseParse(
                          "DeepSeek SSE parse failure (stage=tool.name, category=empty)",
                        )
                      Some(_) =>
                        raise @posoco.ModelError::ResponseParse(
                          "DeepSeek SSE parse failure (stage=tool.name, category=wrong_type)",
                        )
                      None => None
                    }
                    let a : String? = match f.get("arguments") {
                      Some(String(s)) => Some(s)
                      Some(_) =>
                        raise @posoco.ModelError::ResponseParse(
                          "DeepSeek SSE parse failure (stage=tool.arguments, category=wrong_type)",
                        )
                      None => None
                    }
                    if n is None && a is None {
                      raise @posoco.ModelError::ResponseParse(
                        "DeepSeek SSE parse failure (stage=tool.function, category=empty)",
                      )
                    }
                    (n, a)
                  }
                  Some(_) =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek SSE parse failure (stage=tool.function, category=wrong_type)",
                    )
                  None =>
                    raise @posoco.ModelError::ResponseParse(
                      "DeepSeek SSE parse failure (stage=tool.function, category=missing)",
                    )
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
              _ =>
                raise @posoco.ModelError::ResponseParse(
                  "DeepSeek SSE parse failure (stage=tool, category=not_object)",
                )
            }
          }
        Some(_) =>
          raise @posoco.ModelError::ResponseParse(
            "DeepSeek SSE parse failure (stage=delta.tool_calls, category=wrong_type)",
          )
        None => ()
      }
    }
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=delta, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=delta, category=missing)",
      )
  }
  false
}
