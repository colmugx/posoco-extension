///|
/// No dedicated compact endpoint exists, so the transcript is replaced by a
/// dense summary from one non-streaming call with thinking off. Native+js
/// only: `@http` is unavailable on wasm.

///|
/// POST one chat-completions request body and decode the JSON response,
/// with the same transport/status/parse error classification `chat` applies.
/// `stage` labels the failure messages (e.g. "chat", "compact").
async fn OpenCodeZenModelPort::zen_post_chat_json(
  self : OpenCodeZenModelPort,
  body : Json,
  stage : String,
) -> Json raise @posoco.ModelError {
  let headers = build_headers(self.config)
  let url = chat_url(self.config)
  let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "opencode-zen transport failure (stage=post): " + err.to_string(),
      )
  }
  if !is_zen_http_success(response.code) {
    let byte_length = body_data.binary().length()
    let text = body_data.text() catch {
      _ =>
        raise @posoco.ModelError::Transport(
          format_zen_http_error(
            "\{stage}.http_status",
            response.code,
            BodyBytesInvalidUtf8(byte_length),
          ),
        )
    }
    match
      classify_zen_http_status(
        "\{stage}.http_status",
        response.code,
        BodyText(text),
        now_ms=@async.now(),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "opencode-zen response parse failure (stage=decode_utf8, category=invalid_utf8, body_bytes=\{body_data.binary().length()})",
      )
  }
  @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "opencode-zen response parse failure (stage=json, category=malformed, body_chars=\{body_text.length()})",
      )
  }
}

///|
/// Render one content block array: text verbatim, images as placeholders.
fn zen_render_content(content : Array[@posoco.Content]) -> String {
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
/// Render one transcript message as a labeled block for the summarize call.
fn zen_render_message(message : @posoco.Message) -> String {
  match message {
    SystemMessage(content~) => "system: \{zen_render_content(content)}"
    UserMessage(content~) => "user: \{zen_render_content(content)}"
    AssistantMessage(content~, tool_calls~, ..) => {
      let head = "assistant: \{zen_render_content(content)}"
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
        ToolReportedError(content~, ..) => "error: \{content}"
        RuntimeFailure(message~, ..) => "runtime failure: \{message}"
        NotExecuted(..) => "not executed"
      }
      "tool \{tool_name.to_string()}: \{outcome_text}"
    }
  }
}

///|
/// Build the summarize request: a fixed instruction plus the rendered
/// transcript. The summary only needs substance, not fidelity — tool calls
/// and outcomes are summarized inline, and images count as placeholders.
fn zen_compact_messages(
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  [
    SystemMessage(content=[
      Text(
        "You are a summarization engine for a coding agent's conversation. Produce a dense, self-contained summary of the transcript below so the conversation can continue with full context: tasks and their status, key decisions and their reasons, important file paths, identifiers, and unresolved problems with next steps. Write plain prose with short bullet lines where it helps. Do not ask questions. Output only the summary.",
      ),
    ]),
    UserMessage(content=[
      Text(messages.map(fn(m) { zen_render_message(m) }).join("\n\n")),
    ]),
  ]
}

///|
pub impl @posoco.ModelPort for OpenCodeZenModelPort with fn compact(
  self : OpenCodeZenModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let body = build_chat_request(
    zen_compact_messages(messages.to_owned()),
    [],
    options,
    self.config.model,
    false,
    false,
    None,
    false,
  )
  let resp_json = self.zen_post_chat_json(body, "compact")
  let completion = decode_chat_response(resp_json)
  let summary = completion.message.content
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
      "opencode-zen compact produced an empty summary",
    )
  }
  @posoco.CompactResult::{
    compacted_messages: [UserMessage(content=[Text(summary)])],
    mode: @posoco.CompactMode::Replace,
  }
}
