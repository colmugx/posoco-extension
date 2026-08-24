///|
/// HTTP error classification for z.ai.
///
/// 429 is a quota verdict and MUST keep the body: z.ai states the flush time
/// in the message text (codes 1308/1310/1316–1321), and those verdicts are
/// what makes auto-resume schedulable. Transient 429s (1302 concurrency,
/// 1305 overload) carry no reset time. Every other non-2xx keeps the
/// redacted DeepSeek-style summary — provider payloads never cross into
/// generic transport messages.

///|
/// z.ai is UTC+8 native; flush times without an explicit offset are +08:00.
const ZAI_DEFAULT_TZ_OFFSET_MINUTES : Int = 480

///|
fn is_zai_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// Read the error body of a streamed non-2xx response, bounded. `None` when
/// the body could not be read at all.
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
/// Classify a non-2xx status. `body_text` may be the empty string when the
/// body was unavailable; the 429 classifier then reports an unschedulable
/// verdict.
fn classify_zai_http_error(
  stage : String,
  status : Int,
  body_text : String,
  now_ms~ : Int64,
) -> @posoco.ModelError? {
  if is_zai_http_success(status) {
    return None
  }
  if status == 429 {
    return @chatkit.classify_chat_completions_http_error(
      status,
      body_text,
      default_tz_offset_minutes=ZAI_DEFAULT_TZ_OFFSET_MINUTES,
      now_ms~,
    )
  }
  Some(
    @posoco.ModelError::Transport(
      "zai HTTP error (stage=\{stage}, status=\{status}, body_chars=\{body_text.length()})",
    ),
  )
}
