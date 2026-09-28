///|
/// Max characters per synced message (upstream MAX_MESSAGE_CHARS = 20_000).
const NMEM_MAX_MESSAGE_CHARS : Int = 20000

///|
/// First `limit` UTF-16 code units of `text`, shortened by one when the cut
/// would split a surrogate pair (string slicing raises at surrogate
/// boundaries; upstream JS simply splits the pair, which MoonBit strings
/// cannot represent).
fn take_prefix(text : String, limit : Int) -> String {
  if text.length() <= limit {
    text
  } else {
    let mut end = limit
    let edge : UInt16 = text[end - 1]
    let high_surrogate_min : UInt16 = 55296
    let high_surrogate_max : UInt16 = 56319
    if edge >= high_surrogate_min && edge <= high_surrogate_max {
      end = end - 1
    }
    text[0:end].to_owned()
  }
}

///|
/// Cap a message at NMEM_MAX_MESSAGE_CHARS and append the upstream truncation
/// marker (host label derived from `source_app`).
fn truncate_message(text : String, source_app : String) -> String {
  if text.length() <= NMEM_MAX_MESSAGE_CHARS {
    text
  } else {
    "\{take_prefix(text, NMEM_MAX_MESSAGE_CHARS)}\n\n[\{host_label(source_app)} message truncated by Nowledge Mem plugin]"
  }
}

///|
/// Normalize one content part: text passes through,
/// images become a placeholder.
fn part_to_text(part : @posoco.Content) -> String {
  match part {
    @posoco.Content::Text(text) => text
    @posoco.Content::Image(..) => "[Image]"
  }
}

///|
/// Join content parts with "\n", dropping empty segments.
fn parts_to_text(parts : Array[@posoco.Content]) -> String {
  parts
  .filter_map(fn(part) {
    match part_to_text(part) {
      "" => None
      text => Some(text)
    }
  })
  .join("\n")
}

///|
/// Assistant message text: content parts plus one `[Tool: name]` line per
/// requested tool call. Reasoning is never synced.
fn assistant_text(
  parts : Array[@posoco.Content],
  tool_calls : Array[@posoco.ToolCall],
) -> String {
  let tool_lines = tool_calls
    .map(fn(call) { "[Tool: \{call.name.to_string()}]" })
    .join("\n")
  if tool_calls.is_empty() {
    parts_to_text(parts)
  } else {
    match parts_to_text(parts) {
      "" => tool_lines
      text => "\{text}\n\{tool_lines}"
    }
  }
}

///|
/// Model-visible text of a tool outcome — the same surface a model adaptor
/// sends in the tool-role message.
fn outcome_visible_text(outcome : @posoco.ToolOutcome) -> String {
  match outcome {
    @posoco.ToolOutcome::Success(content~, ..) => content
    @posoco.ToolOutcome::SuccessWithAttachments(content~, ..) => content
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => content
    @posoco.ToolOutcome::RuntimeFailure(message~, ..) => message
    @posoco.ToolOutcome::NotExecuted(reason~, ..) => reason.to_string()
  }
}

///|
/// Model-visible transcript message for a terminal tool-call Observer
/// event — the same `ToolMessage` a model adaptor writes for the outcome.
/// The `before_model` snapshot only carries tool outcomes from earlier
/// rounds, so the Observer completes the current round from these events
/// (the assistant-side twin is `record_assistant`). `None` for every
/// non-terminal node and for `ToolCallAbandoned`: an abandoned call has no
/// outcome, so the model never sees one and there is nothing to sync.
pub fn tool_event_message(event : @posoco.TurnEvent) -> @posoco.Message? {
  match event {
    @posoco.TurnEvent::ToolCallSucceeded(
      call~,
      content~,
      structured~,
      attachments~
    ) => {
      let outcome = if attachments.is_empty() {
        @posoco.ToolOutcome::Success(content~, structured~)
      } else {
        @posoco.ToolOutcome::SuccessWithAttachments(
          content~,
          structured~,
          attachments~,
        )
      }
      Some(
        @posoco.Message::ToolMessage(
          call_id=call.call_id,
          tool_name=call.name,
          outcome~,
        ),
      )
    }
    @posoco.TurnEvent::ToolCallFailed(call~, failure~) => {
      let outcome = match failure {
        ReportedError(content~, structured~) =>
          @posoco.ToolOutcome::ToolReportedError(content~, structured~)
        Runtime(category~, message~) =>
          @posoco.ToolOutcome::RuntimeFailure(error_category=category, message~)
      }
      Some(
        @posoco.Message::ToolMessage(
          call_id=call.call_id,
          tool_name=call.name,
          outcome~,
        ),
      )
    }
    @posoco.TurnEvent::ToolCallRejected(call~, reason~) =>
      Some(
        @posoco.Message::ToolMessage(
          call_id=call.call_id,
          tool_name=call.name,
          outcome=@posoco.ToolOutcome::NotExecuted(
            reason~,
            original_call_id=call.call_id,
          ),
        ),
      )
    _ => None
  }
}

///|
/// Build one thread message, or `None` when the normalized content is empty.
/// `external_id` embeds the ORIGINAL input index so ids stay stable when
/// earlier entries are skipped.
fn build_thread_message(
  role : NmemRole,
  raw_content : String,
  config~ : NmemConfig,
  session_id~ : String,
  index~ : Int,
) -> NmemThreadMessage? {
  let trimmed = raw_content.trim().to_owned()
  if trimmed == "" {
    None
  } else {
    Some({
      role,
      content: truncate_message(trimmed, config.source_app),
      metadata: Map::from_array([
        (
          "external_id",
          Json::string("\{config.source_app}-\{session_id}-\{index}"),
        ),
        ("source_app", Json::string(config.source_app)),
      ]),
    })
  }
}

///|
/// Map a kernel transcript snapshot (as captured by `Hook::before_model`) to
/// Nowledge Mem thread messages.
///
/// - SystemMessage is skipped: index 0 of a before_model payload is the
///   aggregated system prompt, not user transcript (design §10-2).
/// - Core's injected session-opening memory message is filtered the same
///   way: injected context is not user speech — and dropping it keeps the
///   thread title the first real user message.
/// - ToolMessage becomes Assistant carrying the outcome's model-visible text.
/// - Messages whose normalized content is empty are dropped.
pub fn map_messages(
  messages : Array[@posoco.Message],
  config~ : NmemConfig,
  session_id~ : String,
) -> Array[NmemThreadMessage] {
  let result : Array[NmemThreadMessage] = []
  for index, message in messages {
    let mapped : NmemThreadMessage? = match message {
      @posoco.Message::SystemMessage(..) => None
      @posoco.Message::UserMessage(content~) =>
        if is_injected_memory_message(message) {
          None
        } else {
          build_thread_message(
            User,
            parts_to_text(content),
            config~,
            session_id~,
            index~,
          )
        }
      @posoco.Message::AssistantMessage(content~, tool_calls~, ..) =>
        build_thread_message(
          Assistant,
          assistant_text(content, tool_calls),
          config~,
          session_id~,
          index~,
        )
      @posoco.Message::ToolMessage(outcome~, ..) =>
        build_thread_message(
          Assistant,
          outcome_visible_text(outcome),
          config~,
          session_id~,
          index~,
        )
    }
    match mapped {
      Some(msg) => result.push(msg)
      None => ()
    }
  }
  result
}
