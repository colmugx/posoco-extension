// compact.mbt — Kimi client-side compaction via one extra non-streaming
// chat call. Kimi has no compact endpoint; the flow mirrors kimi-cli's
// SimpleCompaction: keep the last 2 user/assistant messages verbatim,
// summarize everything older with the structured XML template (thinking
// stays as configured; kimi-cli likewise drops think parts from the
// RESULT only, which falls out of taking just the Text blocks).

///|
/// Index of the message that starts the preserved tail: the second
/// user/assistant message counting from the end. The boundary lands on a
/// UserMessage or AssistantMessage by construction, so a ToolMessage is
/// never separated from the assistant that issued the call. Returns None
/// when the transcript has fewer than two user/assistant messages.
fn kimi_tail_start(messages : Array[@posoco.Message]) -> Int? {
  let mut seen = 0
  let mut i = messages.length() - 1
  while i >= 0 {
    match messages[i] {
      UserMessage(..) | AssistantMessage(..) => {
        seen += 1
        if seen == 2 {
          return Some(i)
        }
      }
      _ => ()
    }
    i -= 1
  }
  None
}

///|
/// Split the transcript into (head to summarize, tail to keep verbatim).
/// None when there is nothing to summarize.
fn kimi_compact_split(
  messages : Array[@posoco.Message],
) -> (Array[@posoco.Message], Array[@posoco.Message])? {
  let tail_start = match kimi_tail_start(messages) {
    Some(i) => i
    None => return None
  }
  if tail_start == 0 {
    return None
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
/// The summary text of a compact completion: Text blocks only (think and
/// image payloads never enter the new context, matching kimi-cli's
/// ThinkPart dropping).
fn kimi_summary_text(completion : @posoco.Completion) -> String {
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
/// One non-streaming chat call producing the summary: same transport,
/// headers, thinking resolution and error classification as `chat`, with
/// an empty toolset (kimi-cli's EmptyToolset).
async fn KimiModelPort::kimi_compact_completion(
  self : KimiModelPort,
  prompt_messages : Array[@posoco.Message],
  options : @posoco.ChatOptions,
) -> @posoco.Completion raise @posoco.ModelError {
  let (thinking_json, reasoning_effort_str) = resolve_thinking_config(
    self.config.model,
    self.config.thinking_efforts,
    self.config.reasoning_effort,
  )
  // k2.6 must not set temperature — same rule as chat.
  let safe_options : @posoco.ChatOptions = if self.config.model == "kimi-k2.6" {
    @posoco.ChatOptions::{
      temperature: None,
      max_output_tokens: options.max_output_tokens,
    }
  } else {
    options
  }
  let body = build_chat_request(
    self.ctx,
    prompt_messages,
    [],
    safe_options,
    self.config.model,
    false,
    thinking_json,
    None,
    reasoning_effort_str~,
    supports_images=self.config.supports_images,
  )
  let headers = build_headers(self.config)
  let url = chat_url(self.config)
  let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "kimi transport failure (stage=compact_post): " + err.to_string(),
      )
  }
  if !is_kimi_http_success(response.code) {
    let body_text = body_data.text() catch { _ => "" }
    match
      classify_kimi_http_status(
        "compact.http_status",
        response.code,
        BodyBytesUtf8(body_data.binary().length()),
        body_text~,
        retry_after=retry_after_header(response),
        now_ms=@async.now(),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "kimi compact parse failure (stage=decode_utf8, category=invalid_utf8)",
      )
  }
  let resp_json : Json = @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "kimi compact parse failure (stage=json, category=malformed)",
      )
  }
  decode_chat_response(resp_json)
}

///|
/// ModelPort implementation — compact. Summarize everything older than the
/// last two user/assistant messages with one non-streaming call and Replace
/// the transcript (head summary as a single user message + verbatim tail).
pub impl @posoco.ModelPort for KimiModelPort with fn compact(
  self : KimiModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let (head, tail) = match kimi_compact_split(messages.to_owned()) {
    Some(split) => split
    None =>
      raise @posoco.ModelError::ResponseParse(
        "kimi compact has nothing to summarize (fewer than two user/assistant messages)",
      )
  }
  let prompt = @compact_summary.build_summary_prompt(
    @compact_summary.SummaryTemplate::KimiXml,
    @compact_summary.serialize_for_summary(head),
  )
  let completion = self.kimi_compact_completion(prompt, options)
  let summary = kimi_summary_text(completion)
  if summary.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "kimi compact produced an empty summary",
    )
  }
  @compact_summary.build_replace_result(summary, tail)
}
