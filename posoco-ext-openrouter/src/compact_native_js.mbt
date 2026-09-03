///|
/// compact_native_js.mbt — ModelPort::compact via the summary kit.
///
/// OpenRouter exposes no dedicated compact endpoint, so compaction is
/// client-orchestrated: cut the transcript at a safe boundary (keep the
/// most recent 20k tokens), serialize the head, ask the model for a
/// structured summary in one non-streaming call (thinking off — the summary
/// must be plain prose, not a reasoning exercise), and Replace the
/// transcript with (summary user message + verbatim tail). The
/// URL/headers/encode/decode and error classification are exactly the ones
/// `chat` uses.
///
/// Compiled on native and js only (`@http` is unavailable on wasm);
/// compact_wasm_fallback.mbt satisfies the trait elsewhere.

///|
/// POST one chat-completions request body and decode the JSON response,
/// with the same transport/status/parse error classification `chat` applies.
/// `stage` labels the failure messages (e.g. "chat", "compact").
async fn OpenRouterModelPort::openrouter_post_chat_json(
  self : OpenRouterModelPort,
  body : Json,
  stage : String,
) -> Json raise @posoco.ModelError {
  let headers = build_headers(self.config)
  let url = chat_url(self.config)
  let (response, body_data) = @http.post(url, body.stringify(), headers~) catch {
    err =>
      raise @posoco.ModelError::Transport(
        "openrouter transport failure (stage=post): " + err.to_string(),
      )
  }
  if !is_openrouter_http_success(response.code) {
    let byte_length = body_data.binary().length()
    let text = body_data.text() catch {
      _ =>
        raise @posoco.ModelError::Transport(
          format_openrouter_http_error(
            "\{stage}.http_status",
            response.code,
            BodyBytesInvalidUtf8(byte_length),
          ),
        )
    }
    match
      classify_openrouter_http_status(
        "\{stage}.http_status",
        response.code,
        BodyText(text),
        retry_after_header=retry_after_header(response),
        rate_limit_reset_header=rate_limit_reset_header(response),
        now_ms=@async.now(),
      ) {
      Some(err) => raise err
      None => ()
    }
  }
  let body_text = body_data.text() catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "openrouter response parse failure (stage=decode_utf8, category=invalid_utf8, body_bytes=\{body_data.binary().length()})",
      )
  }
  @json.parse(body_text) catch {
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "openrouter response parse failure (stage=json, category=malformed, body_chars=\{body_text.length()})",
      )
  }
}

///|
/// ModelPort implementation — compact. One non-streaming summarize call via
/// the summary kit, thinking off, tools empty; the summary text replaces
/// the transcript head (mode Replace) as a single user message followed by
/// the kept tail.
pub impl @posoco.ModelPort for OpenRouterModelPort with fn compact(
  self : OpenRouterModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let all = messages.to_owned()
  let cut = @compact_summary.select_cut(all, 20000)
  if cut.head_end == 0 {
    raise @posoco.ModelError::ResponseParse(
      "openrouter compact has nothing to summarize",
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
  // Thinking off for the summarize call: the summary must be plain prose,
  // not a reasoning exercise, and must not burn reasoning tokens.
  let config = { ..self.config, thinking: false, reasoning_effort: None, }
  let body = build_chat_request(config, prompt, [], options, false)
  let resp_json = self.openrouter_post_chat_json(body, "compact")
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
      "openrouter compact produced an empty summary",
    )
  }
  @compact_summary.build_replace_result(summary, tail)
}
