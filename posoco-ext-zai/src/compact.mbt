// compact.mbt — Z.AI client-side compaction via the summary kit: cut the
// transcript at a safe boundary (keep the most recent 20k tokens), ask the
// model for a structured summary in one extra non-streaming call, and
// Replace the transcript with (summary user message + verbatim tail).

///|
/// One non-streaming chat call producing the summary: same transport,
/// headers, thinking resolution and error classification as `chat`, with
/// an empty toolset.
async fn ZaiModelPort::zai_compact_completion(
  self : ZaiModelPort,
  prompt_messages : Array[@posoco.Message],
  options : @posoco.ChatOptions,
) -> @posoco.Completion raise @posoco.ModelError {
  let (thinking_enabled, effort_str) = self.thinking_state()
  let body = build_chat_request(
    prompt_messages,
    [],
    options,
    self.config.model,
    false,
    thinking_enabled,
    effort_str,
  )
  let (response, body_data) = @http.post(
    chat_url(self.config),
    body.stringify(),
    headers=build_headers(self.config),
  ) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "zai transport failure (stage=compact_post): " + err.to_string(),
      )
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "zai compact parse failure (stage=decode_utf8, body_bytes=\{body_data.binary().length()})",
      )
  }
  if !is_zai_http_success(response.code) {
    match
      classify_zai_http_error(
        "compact.http_status",
        response.code,
        body_text,
        now_ms=@async.now(),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let resp_json : Json = @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "zai compact parse failure (stage=json, body_chars=\{body_text.length()})",
      )
  }
  decode_chat_response(resp_json)
}

///|
/// ModelPort implementation — compact. Keep the most recent 20k tokens
/// verbatim, summarize the head with the structured Markdown template, and
/// Replace. The window is a fixed parity default: zai reports no
/// context_window yet, so auto-compact stays disabled until it does
/// (unknown windows are never guessed) and this value only bounds manual
/// compaction.
pub impl @posoco.ModelPort for ZaiModelPort with fn compact(
  self : ZaiModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let all = messages.to_owned()
  let cut = @compact_summary.select_cut(all, 20000)
  if cut.head_end == 0 {
    raise @posoco.ModelError::ResponseParse(
      "zai compact has nothing to summarize",
    )
  }
  let head : Array[@posoco.Message] = []
  let tail : Array[@posoco.Message] = []
  for i in 0..<cut.head_end {
    head.push(all[i])
  }
  for i in cut.kept_from..<all.length() {
    tail.push(all[i])
  }
  let prompt = @compact_summary.build_summary_prompt(
    @compact_summary.SummaryTemplate::StructuredMd,
    @compact_summary.serialize_for_summary(head),
  )
  let completion = self.zai_compact_completion(prompt, options)
  let summary = zai_summary_text(completion)
  if summary.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "zai compact produced an empty summary",
    )
  }
  @compact_summary.build_replace_result(summary, tail)
}

///|
/// The summary text of a compact completion: Text blocks only.
fn zai_summary_text(completion : @posoco.Completion) -> String {
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
