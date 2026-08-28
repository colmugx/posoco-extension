///|
/// Shared HTTP utilities for kimi API — error body summary, status
/// classification, stream termination classification, and tool-call
/// validation. All items are package-visible so they can be used across
/// files in this package (kimi.mbt and tests).

///|
/// Redacted non-2xx body metadata. Keeping this as an ADT prevents the raw
/// provider body from crossing the HTTP-error formatting boundary.
priv enum KimiErrorBodySummary {
  BodyBytesUtf8(Int)
  BodyBytesInvalidUtf8(Int)
  BodyUnavailable
}

///|
/// Format an HTTP failure from redacted metadata.
fn format_kimi_http_error(
  stage : String,
  status : Int,
  body_summary : KimiErrorBodySummary,
) -> String {
  let summary = match body_summary {
    BodyBytesUtf8(length) => "body_bytes=\{length}, body_category=utf8"
    BodyBytesInvalidUtf8(length) =>
      "body_bytes=\{length}, body_category=invalid_utf8"
    BodyUnavailable => "body_category=unavailable"
  }
  "kimi HTTP error (stage=\{stage}, status=\{status}, \{summary})"
}

///|
fn is_kimi_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// Pure HTTP-status classifier. Non-quota failures keep the redacted
/// summary. A quota verdict keeps the body: 429 (Moonshot's plan throttles
/// are the documented 5-hour/monthly messages, also phrased "The engine is
/// currently overloaded" with `error.type: rate_limit_reached_error`) and
/// 403 (the coding plan's "You've reached your 5-hour usage limit" quota
/// wall — the kit gates non-429 bodies on quota phrasing so auth 403s stay
/// Transport). The body distinguishes quota walls from real overload; the
/// message text carries no timestamp, so the documented wait signal is the
/// `Retry-After` header, passed here by the caller when one was present.
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
  Some(
    @posoco.ModelError::Transport(
      format_kimi_http_error(stage, status, body_summary),
    ),
  )
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
fn retry_after_header(response : @http.Response) -> String? {
  response.headers.get(@http.CaseInsensitiveString("Retry-After"))
}

///|
/// Pure classification for stream termination; used by the HTTP loop and
/// offline tests so EOF is never inferred from accumulated content.
priv enum KimiStreamTermination {
  ExplicitTerminal
  CleanEof
  TransportFailure
}

///|
fn classify_kimi_stream_termination(
  termination : KimiStreamTermination,
) -> @posoco.ModelError? {
  match termination {
    ExplicitTerminal => None
    CleanEof =>
      Some(
        @posoco.ModelError::ResponseParse(
          "kimi SSE truncated (stage=eof, terminal_marker=missing)",
        ),
      )
    TransportFailure =>
      Some(
        @posoco.ModelError::Transport(
          "kimi transport failure (stage=read_stream)",
        ),
      )
  }
}

///|
/// Reject incomplete tool-call builders before delegating JSON assembly.
fn validate_kimi_stream_tool_calls(
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  for tc in acc.tool_calls {
    if tc.id == "" {
      raise @posoco.ModelError::ResponseParse(
        "kimi SSE parse failure (stage=tool.id, category=missing)",
      )
    }
    if tc.name == "" {
      raise @posoco.ModelError::ResponseParse(
        "kimi SSE parse failure (stage=tool.name, category=missing)",
      )
    }
    if tc.arguments_json() == "" {
      raise @posoco.ModelError::ResponseParse(
        "kimi SSE parse failure (stage=tool.arguments, category=missing)",
      )
    }
    let _ : Json = @json.parse(tc.arguments_json()) catch {
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "kimi SSE parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{tc.arguments_json().length()})",
        )
    }
  }
}
