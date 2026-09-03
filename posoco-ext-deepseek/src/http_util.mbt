///|
/// Shared HTTP utilities for DeepSeek API — error body summary, status
/// classification, stream termination classification, and tool-call
/// validation. All items are package-visible so they can be used across
/// files in this package (deepseek.mbt, fim.mbt, tests, etc.).

///|
/// Redacted non-2xx body metadata. Keeping this as an ADT prevents the raw
/// provider body from crossing the HTTP-error formatting boundary.
priv enum DeepSeekErrorBodySummary {
  BodyBytesUtf8(Int)
  BodyBytesInvalidUtf8(Int)
  BodyReadFailed
  BodyUnavailable
}

///|
/// Format an HTTP failure from redacted metadata.
fn format_deepseek_http_error(
  stage : String,
  status : Int,
  body_summary : DeepSeekErrorBodySummary,
) -> String {
  let summary = match body_summary {
    BodyBytesUtf8(length) => "body_bytes=\{length}, body_category=utf8"
    BodyBytesInvalidUtf8(length) =>
      "body_bytes=\{length}, body_category=invalid_utf8"
    BodyReadFailed => "body_category=read_failed"
    BodyUnavailable => "body_category=unavailable"
  }
  "DeepSeek HTTP error (stage=\{stage}, status=\{status}, \{summary})"
}

///|
fn is_deepseek_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// Pure HTTP-status classifier. It accepts only redacted body metadata, so a
/// provider payload can never cross into the observable error message.
fn classify_deepseek_http_status(
  stage : String,
  status : Int,
  body_summary : DeepSeekErrorBodySummary,
) -> @posoco.ModelError? {
  if is_deepseek_http_success(status) {
    None
  } else {
    Some(
      @posoco.ModelError::Transport(
        format_deepseek_http_error(stage, status, body_summary),
      ),
    )
  }
}

///|
/// Drain a non-2xx response without exposing provider payloads.
async fn read_error_body_summary(
  client : @http.Client,
) -> DeepSeekErrorBodySummary {
  let data = client.read_all() catch { _ => return BodyReadFailed }
  let byte_length = data.binary().length()
  let _ = data.text() catch { _ => return BodyBytesInvalidUtf8(byte_length) }
  BodyBytesUtf8(byte_length)
}

///|
/// Pure classification for stream termination; used by the HTTP loop and
/// offline tests so EOF is never inferred from accumulated content.
/// (Transport failures raise `ModelError::Transport` directly at the read
/// site so the underlying error detail is preserved.)
priv enum DeepSeekStreamTermination {
  ExplicitTerminal
  CleanEof
}

///|
fn classify_deepseek_stream_termination(
  termination : DeepSeekStreamTermination,
) -> @posoco.ModelError? {
  match termination {
    ExplicitTerminal => None
    CleanEof =>
      Some(
        @posoco.ModelError::ResponseParse(
          "DeepSeek SSE truncated (stage=eof, terminal_marker=missing)",
        ),
      )
  }
}

///|
/// Reject incomplete tool-call builders before delegating JSON assembly.
fn validate_deepseek_stream_tool_calls(
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  for tc in acc.tool_calls {
    if tc.id == "" {
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=tool.id, category=missing)",
      )
    }
    if tc.name == "" {
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=tool.name, category=missing)",
      )
    }
    if tc.arguments_json() == "" {
      raise @posoco.ModelError::ResponseParse(
        "DeepSeek SSE parse failure (stage=tool.arguments, category=missing)",
      )
    }
    let _ : Json = @json.parse(tc.arguments_json()) catch {
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "DeepSeek SSE parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{tc.arguments_json().length()})",
        )
    }
  }
}
