///|
/// Index of the message that starts the preserved tail: the second
/// user/assistant message counting from the end.
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
async fn KimiModelPort::kimi_compact_completion(
  self : KimiModelPort,
  prompt_messages : Array[@posoco.Message],
) -> @posoco.Completion raise @posoco.ModelError {
  let body = build_responses_request(
    prompt_messages,
    [],
    { temperature: None, max_output_tokens: None, },
    self.config.model,
    false,
    None,
    reasoning_effort=None,
  )
  let headers = build_headers(self.config)
  let (response, body_data) = @http.post(
    responses_url(self.config),
    body.stringify(),
    headers~,
  ) catch {
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
  decode_responses_response(resp_json)
}

///|
pub impl @posoco.ModelPort for KimiModelPort with fn compact(
  self : KimiModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
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
  let completion = self.kimi_compact_completion(prompt)
  let summary = kimi_summary_text(completion)
  if summary.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "kimi compact produced an empty summary",
    )
  }
  @compact_summary.build_replace_result(summary, tail)
}
