///|

///|
/// Redacted non-2xx body metadata; the raw body never enters error text.
priv enum KimiErrorBodySummary {
  BodyBytesUtf8(Int)
  BodyUnavailable
}

///|
fn format_kimi_http_error(
  stage : String,
  status : Int,
  body_summary : KimiErrorBodySummary,
) -> String {
  let summary = match body_summary {
    BodyBytesUtf8(length) => "body_bytes=\{length}, body_category=utf8"
    BodyUnavailable => "body_category=unavailable"
  }
  "kimi HTTP error (stage=\{stage}, status=\{status}, \{summary})"
}

///|
fn is_kimi_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
fn classify_kimi_http_status(
  stage : String,
  status : Int,
  body_summary : KimiErrorBodySummary,
  body_text? : String = "",
  retry_after? : String? = None,
  now_ms~ : Int64,
) -> @posoco.ModelError? {
  if is_kimi_http_success(status) {
    return None
  }
  if status == 429 || status == 403 {
    let verdict = @chatkit.classify_chat_completions_http_error(
      status,
      body_text,
      retry_after_header=retry_after,
      now_ms~,
    )
    match verdict {
      Some(err) => return Some(err)
      None => ()
    }
  }
  if status == 401 {
    return Some(
      @posoco.ModelError::Transport(
        format_kimi_http_error(stage, status, body_summary) +
        ": platform (api.moonshot.ai) and coding (api.kimi.com) credentials are not interchangeable; check base_url against the credential kind",
      ),
    )
  }
  if status == 400 &&
    (body_text.contains("total message size") || body_text.contains("2097152")) {
    return Some(
      @posoco.ModelError::Transport(
        format_kimi_http_error(stage, status, body_summary) +
        ": the coding host rejects message payloads over 2 MiB (limit 2097152 bytes)",
      ),
    )
  }
  Some(
    @posoco.ModelError::Transport(
      format_kimi_http_error(stage, status, body_summary),
    ),
  )
}

///|
/// Bounded read of a streamed non-2xx error body.
async fn read_error_body_text(client : @http.Client) -> String? {
  let data = client.read_all() catch { _ => return None }
  let text = data.text() catch { _ => return None }
  if text.length() > 2048 {
    Some(text.sub(start=0, end=2048).to_owned())
  } else {
    Some(text)
  }
}

///|
fn retry_after_header(response : @http.Response) -> String? {
  response.headers.get(@http.CaseInsensitiveString("Retry-After"))
}
