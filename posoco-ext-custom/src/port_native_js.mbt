///|
/// port_native_js.mbt — the wire-opening half of the custom-provider
/// ModelPort. Compiled on native, wasm, and js (`@http` is unavailable on
/// wasm-gc).
///
/// `chat` dispatches on the declared protocol; `compact` runs through the same
/// wire with reasoning turned off and no tools, so one summarize strategy
/// covers all three dialects and the endpoint sees a request shaped exactly
/// like a normal turn.

///|
async fn read_custom_error_body(client : @http.Client) -> CustomErrorBody {
  let data = client.read_all() catch { _ => return BodyReadFailed }
  let byte_length = data.binary().length()
  let text = data.text() catch { _ => return BodyBytesInvalidUtf8(byte_length) }
  BodyText(text)
}

///|
/// One call on the configured wire. Every branch owns its own transport; the
/// dispatch itself never retries, and never falls back to another protocol —
/// a wrong `protocol` setting must fail loudly, not quietly change shape.
async fn CustomModelPort::custom_call(
  self : CustomModelPort,
  scope : @posoco.InvocationScope,
  config : CustomConfig,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  match config.protocol {
    ChatCompletions =>
      self.chat_chat_completions(
        scope, config, messages, tools, options, stream,
      )
    Responses =>
      self.chat_responses(scope, config, messages, tools, options, stream)
    Messages =>
      self.chat_messages(scope, config, messages, tools, options, stream)
  }
}

///|
pub impl @posoco.ModelPort for CustomModelPort with fn chat(
  self : CustomModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let messages_owned = messages.to_owned()
  self.custom_call(scope, self.config, messages_owned, tools, options, stream)
}

///|
/// Rendered transcript for a summary request. Images are named, never sent:
/// compaction must not depend on the model's image support.
fn custom_render_content(content : Array[@posoco.Content]) -> String {
  content
  .map(fn(block) {
    match block {
      Text(text) => text
      Image(media_type~, ..) => "[image: \{media_type}]"
    }
  })
  .join(" ")
}

///|
fn custom_render_message(message : @posoco.Message) -> String {
  match message {
    SystemMessage(content~) => "system: \{custom_render_content(content)}"
    UserMessage(content~) => "user: \{custom_render_content(content)}"
    AssistantMessage(content~, tool_calls~, ..) => {
      let head = "assistant: \{custom_render_content(content)}"
      let calls = tool_calls.map(fn(call) {
        "  [tool call \{call.name.to_string()} args=\{call.arguments.stringify()}]"
      })
      if calls.is_empty() {
        head
      } else {
        "\{head}\n\{calls.join("\n")}"
      }
    }
    ToolMessage(tool_name~, outcome~, ..) => {
      let outcome_text = match outcome {
        Success(content~, ..) => content
        SuccessWithAttachments(content~, ..) => content
        ToolReportedError(content~, ..) => "error: \{content}"
        RuntimeFailure(message~, ..) => "runtime failure: \{message}"
        NotExecuted(..) => "not executed"
      }
      "tool \{tool_name.to_string()}: \{outcome_text}"
    }
  }
}

///|
fn custom_compact_messages(
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  [
    SystemMessage(content=[
      Text(
        "You are a summarization engine for a coding agent's conversation. Produce a dense, self-contained summary of the transcript below so the conversation can continue with full context: tasks and their status, key decisions and their reasons, important file paths, identifiers, and unresolved problems with next steps. Write plain prose with short bullet lines where it helps. Do not ask questions. Output only the summary.",
      ),
    ]),
    UserMessage(content=[
      Text(messages.map(fn(m) { custom_render_message(m) }).join("\n\n")),
    ]),
  ]
}

///|
pub impl @posoco.ModelPort for CustomModelPort with fn compact(
  self : CustomModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  // The summary must be plain prose: no reasoning surface, no tools. Every
  // other request fact (temperature ceiling, output budget) rides through.
  let config = { ..self.config, reasoning_effort: None, }
  let result = self.custom_call(
    scope,
    config,
    custom_compact_messages(messages.to_owned()),
    [],
    options,
    @posoco.StreamMode::NoStream,
  )
  let summary = result.completion.message.content
    .filter_map(fn(block) {
      match block {
        Text(text) => Some(text)
        Image(..) => None
      }
    })
    .join(" ")
    .trim()
    .to_owned()
  if summary.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "custom provider compact produced an empty summary (wire=" +
      self.config.protocol.to_id() +
      ")",
    )
  }
  @posoco.CompactResult::{
    compacted_messages: [UserMessage(content=[Text(summary)])],
    mode: @posoco.CompactMode::Replace,
  }
}
