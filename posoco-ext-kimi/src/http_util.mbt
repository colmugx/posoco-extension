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
  BodyReadFailed
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
    BodyReadFailed => "body_category=read_failed"
    BodyUnavailable => "body_category=unavailable"
  }
  "kimi HTTP error (stage=\{stage}, status=\{status}, \{summary})"
}

///|
fn is_kimi_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// Pure HTTP-status classifier. It accepts only redacted body metadata, so a
/// provider payload can never cross into the observable error message.
fn classify_kimi_http_status(
  stage : String,
  status : Int,
  body_summary : KimiErrorBodySummary,
) -> @posoco.ModelError? {
  if is_kimi_http_success(status) {
    None
  } else {
    Some(
      @posoco.ModelError::Transport(
        format_kimi_http_error(stage, status, body_summary),
      ),
    )
  }
}

///|
/// T07-B: drain a non-2xx response without exposing provider payloads.
async fn read_error_body_summary(client : @http.Client) -> KimiErrorBodySummary {
  let data = client.read_all() catch { _ => return BodyReadFailed }
  let byte_length = data.binary().length()
  let _ = data.text() catch { _ => return BodyBytesInvalidUtf8(byte_length) }
  BodyBytesUtf8(byte_length)
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
    if tc.arguments_json == "" {
      raise @posoco.ModelError::ResponseParse(
        "kimi SSE parse failure (stage=tool.arguments, category=missing)",
      )
    }
    let _ : Json = @json.parse(tc.arguments_json) catch {
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "kimi SSE parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{tc.arguments_json.length()})",
        )
    }
  }
}
