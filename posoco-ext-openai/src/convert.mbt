///|
/// Compact decode for the OpenAI Responses API.
///
/// The wire-generic items/tool/usage/SSE machinery lives in the shared
/// `posoco-kit-responses` module; this file keeps only the compact-specific
/// decode of `/responses/compact` output items into canonical messages.

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
          "function_call" =>
            pending_calls.push(
              @responses.parse_function_call_item(provider="OpenAI", map),
            )
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
            let text = @responses.message_item_text(provider="OpenAI", map)
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
