// compact.mbt — DeepSeek client-side compaction: the summary request
// REPLAYS the head messages byte for byte and appends the compaction
// instruction as the FINAL user message, so the auxiliary call is a
// genuine prefix of the last routed request and the provider's KV cache
// is reused instead of invalidated. The result replaces the head with one
// checkpoint user message (preamble plus the summary sealed in a
// <cetas-context type="compact"> envelope) followed by the verbatim tail.
// Self-contained on purpose: no compact-kit dependency, this provider's
// replay shape is its own.

///|
/// The compaction directive, delivered as the final user message after the replayed conversation.
const DEEPSEEK_COMPACTION_INSTRUCTION : String =
  #|You are now acting as a compaction engine for this AI coding assistant. Compress the conversation ABOVE into a structured checkpoint that another model will use to continue the work, with no access to the original messages. This is lossless compression: shorten the transcript, never the information — anything you drop is lost to the next model forever.
  #|
  #|Output EXACTLY the Markdown structure below: keep every section, in order. Use terse bullets, not prose paragraphs. Write "(none)" for an empty section — never drop a section.
  #|
  #|## Primary Request and Intent
  #|- [the user's original and evolving goals; quote the exact wording wherever it carries meaning]
  #|
  #|## Key Technical Concepts
  #|- [technologies, frameworks, patterns, and conventions in play]
  #|
  #|## Files and Code
  #|- [exact path: why it matters, key changes or snippets]
  #|
  #|## Errors and Fixes
  #|- [error: how it was resolved, plus any related user feedback]
  #|
  #|## Pending Jobs
  #|- [explicitly requested work not yet completed]
  #|
  #|## Current Work
  #|- [precisely what was in progress at this checkpoint]
  #|
  #|## Next Step
  #|- [the single next action, directly in line with the most recent request, or "(none)"]
  #|
  #|## Critical Context
  #|- [decisions and their rationale, constraints, user preferences, open questions, data needed to continue]
  #|
  #|Compression rules — what must survive:
  #|- Preserve verbatim: file paths, commands, error strings, identifiers, numeric values, function signatures, API shapes, and syntax fragments. Never paraphrase any of these into something a shell or compiler would treat differently.
  #|- Preserve every user instruction, correction, and preference faithfully — corrections especially.
  #|- Preserve uncertainty as uncertainty: record open questions and unresolved errors instead of resolving them by guesswork.
  #|- Drop only what no future step can need: repeated retries, duplicated tool output, superseded plans, social padding. When in doubt, keep it.
  #|- Write concise English engineering prose.
  #|
  #|Output rules:
  #|- Do NOT mention this summarization request or that the context was compacted.
  #|- Output only the checkpoint text: do not call any tool or take any other action.
  #|- If the conversation ABOVE already contains a compaction checkpoint (a <cetas-context type="compact"> envelope), recompress it together with the newer messages: preserve still-true facts, drop stale ones, and merge everything into one consolidated summary under the same structure.

///|
/// Framing of the replacement checkpoint user message, placed before the
/// compact envelope.
const DEEPSEEK_CHECKPOINT_PREAMBLE : String =
  #|This is an automatically generated checkpoint condensing an earlier span of the conversation to free up context. Treat the captured context as established background and build on it without restating it. Continue the task directly from the messages that follow, without acknowledging this checkpoint.

///|
/// The replacement text for the summarized head: the preamble plus the
/// summary sealed in a `<cetas-context type="compact">` envelope (devkit
/// rendering, so envelope-breaking characters in the summary are escaped).
fn ds_compact_checkpoint_text(summary : String) -> String {
  DEEPSEEK_CHECKPOINT_PREAMBLE +
  "\n\n" +
  @devkit.context_envelope(
    ns="cetas",
    kind="compact",
    trust=true,
    content=summary,
  )
}

///|
/// ceil(chars / 4) — the same conservative estimate the compact kits use.
fn ds_compact_estimate_chars(chars : Int) -> Int {
  (chars + 3) / 4
}

///|
/// Visible character count of one message (text content; tool-call name and
/// JSON arguments for assistants; the outcome payload for tool results).
fn ds_compact_message_chars(message : @posoco.Message) -> Int {
  let mut total = 0
  match message {
    SystemMessage(content~) | UserMessage(content~) =>
      for block in content {
        match block {
          Text(text) => total += text.length()
          Image(..) => ()
        }
      }
    AssistantMessage(content~, tool_calls~, ..) => {
      for block in content {
        match block {
          Text(text) => total += text.length()
          Image(..) => ()
        }
      }
      for call in tool_calls {
        total += call.name.to_string().length()
        total += call.arguments.stringify().length()
      }
    }
    ToolMessage(outcome~, ..) =>
      match outcome {
        Success(content~, ..) => total += content.length()
        ToolReportedError(content~, ..) => total += content.length()
        RuntimeFailure(message~, ..) => total += message.length()
        NotExecuted(..) => ()
      }
  }
  total
}

///|
/// Index starting the verbatim tail: walk backwards accumulating estimated
/// tokens until `keep_recent_tokens`, then retreat to the nearest
/// UserMessage boundary so an AssistantMessage and its tool results are
/// never split. The window size is unknown here (never guessed), so the
/// parity default is 20k tokens. Returns None when even the first user
/// message is inside the budget (nothing to summarize).
fn ds_compact_tail_start(messages : Array[@posoco.Message]) -> Int? {
  let mut running = 0
  let mut i = messages.length() - 1
  let mut candidate = -1
  while i >= 0 {
    running += ds_compact_estimate_chars(ds_compact_message_chars(messages[i]))
    if running >= 20_000 {
      candidate = i
      break
    }
    i -= 1
  }
  if candidate < 0 {
    return None
  }
  let mut boundary = candidate
  while boundary > 0 {
    match messages[boundary] {
      UserMessage(..) => break
      _ => boundary -= 1
    }
  }
  if boundary == 0 {
    return None
  }
  Some(boundary)
}

///|
/// Split into (replayed head, verbatim tail). None when there is nothing
/// to summarize.
fn ds_compact_split(
  messages : Array[@posoco.Message],
) -> (Array[@posoco.Message], Array[@posoco.Message])? {
  let tail_start = match ds_compact_tail_start(messages) {
    Some(i) => i
    None => return None
  }
  let head : Array[@posoco.Message] = []
  let tail : Array[@posoco.Message] = []
  for i in 0..<tail_start {
    head.push(messages[i])
  }
  for i in tail_start..<messages.length() {
    tail.push(messages[i])
  }
  Some((head, tail))
}

///|
/// The summary text of a compact completion: Text blocks only.
fn ds_compact_summary_text(completion : @posoco.Completion) -> String {
  completion.message.content
  .filter_map(fn(block) {
    match block {
      Text(text) => Some(text)
      Image(..) => None
    }
  })
  .join(" ")
  .trim()
  .to_owned()
}

///|
/// One non-streaming chat call with the replayed head plus the trailing
/// instruction: same transport, headers, thinking resolution and error
/// classification as `chat`, with an empty toolset.
async fn DeepSeekModelPort::ds_compact_completion(
  self : DeepSeekModelPort,
  head : Array[@posoco.Message],
  options : @posoco.ChatOptions,
) -> @posoco.Completion raise @posoco.ModelError {
  let (thinking_json, effort_str) = self.default_thinking_config()
  let request_messages : Array[@posoco.Message] = []
  // Byte-for-byte replay of the head: genuine prefix of the last routed
  // request, so the KV cache survives.
  for message in head {
    request_messages.push(message)
  }
  request_messages.push(
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text(DEEPSEEK_COMPACTION_INSTRUCTION),
    ]),
  )
  let body = build_chat_request(
    self.ctx,
    request_messages,
    [],
    options,
    self.config.model,
    false,
    thinking_json,
    effort_str,
  )
  let headers = build_headers(self.config)
  let url = chat_url(self.config)
  let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "DeepSeek transport failure (stage=compact_post): " + err.to_string(),
      )
  }
  if !is_deepseek_http_success(response.code) {
    match
      classify_deepseek_http_status(
        "compact.http_status",
        response.code,
        BodyBytesUtf8(body_data.binary().length()),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek compact parse failure (stage=decode_utf8, category=invalid_utf8)",
      )
  }
  let resp_json : Json = @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek compact parse failure (stage=json, category=malformed)",
      )
  }
  decode_chat_response(resp_json)
}

///|
/// ModelPort implementation — compact: replay the head verbatim with the
/// instruction trailing as the final user message, then replace the
/// transcript with one checkpoint user message (summary sealed in a
/// compact envelope) plus the verbatim tail.
pub impl @posoco.ModelPort for DeepSeekModelPort with fn compact(
  self : DeepSeekModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let (head, tail) = match ds_compact_split(messages.to_owned()) {
    Some(split) => split
    None =>
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek compact has nothing to summarize",
      )
  }
  let completion = self.ds_compact_completion(head, options)
  let summary = ds_compact_summary_text(completion)
  if summary.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "DeepSeek compact produced an empty summary",
    )
  }
  let checkpoint : Array[@posoco.Message] = [
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text(ds_compact_checkpoint_text(summary)),
    ]),
  ]
  for message in tail {
    checkpoint.push(message)
  }
  @posoco.CompactResult::{
    compacted_messages: checkpoint,
    mode: @posoco.CompactMode::Replace,
  }
}
