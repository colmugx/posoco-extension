///|
/// Shared HTTP utilities for the OpenAI-compatible adapter — error body
/// summary, status classification, stream termination classification, and
/// tool-call validation. All items are package-visible so they can be used
/// across files in this package (openai_compatible.mbt, sse.mbt, tests).

///|
/// Redacted non-2xx body metadata. Keeping this as an ADT prevents the raw
/// provider body from crossing the HTTP-error formatting boundary.
priv enum OaiCompatErrorBodySummary {
  BodyBytesUtf8(Int)
  BodyBytesInvalidUtf8(Int)
  BodyReadFailed
  BodyUnavailable
}

///|
/// Format an HTTP failure from redacted metadata.
fn format_oai_compat_http_error(
  stage : String,
  status : Int,
  body_summary : OaiCompatErrorBodySummary,
) -> String {
  let summary = match body_summary {
    BodyBytesUtf8(length) => "body_bytes=\{length}, body_category=utf8"
    BodyBytesInvalidUtf8(length) =>
      "body_bytes=\{length}, body_category=invalid_utf8"
    BodyReadFailed => "body_category=read_failed"
    BodyUnavailable => "body_category=unavailable"
  }
  "openai-compatible HTTP error (stage=\{stage}, status=\{status}, \{summary})"
}

///|
fn is_oai_compat_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// Pure HTTP-status classifier. It accepts only redacted body metadata, so a
/// provider payload can never cross into the observable error message.
fn classify_oai_compat_http_status(
  stage : String,
  status : Int,
  body_summary : OaiCompatErrorBodySummary,
) -> @posoco.ModelError? {
  if is_oai_compat_http_success(status) {
    None
  } else {
    Some(
      @posoco.ModelError::Transport(
        format_oai_compat_http_error(stage, status, body_summary),
      ),
    )
  }
}

///|
/// `read_error_body_summary` (the one function that takes an `@http.Client`)
/// lives in chat_native_js.mbt, co-located with the chat impl. The
/// classification helpers below are pure and stay here for every backend.

///|
/// Pure classification for stream termination; used by the HTTP loop and
/// offline tests so EOF is never inferred from accumulated content.
priv enum OaiCompatStreamTermination {
  ExplicitTerminal
  CleanEof
  TransportFailure
}

///|
fn classify_oai_compat_stream_termination(
  termination : OaiCompatStreamTermination,
) -> @posoco.ModelError? {
  match termination {
    ExplicitTerminal => None
    CleanEof =>
      Some(
        @posoco.ModelError::ResponseParse(
          "openai-compatible SSE truncated (stage=eof, terminal_marker=missing)",
        ),
      )
    TransportFailure =>
      Some(
        @posoco.ModelError::Transport(
          "openai-compatible transport failure (stage=read_stream)",
        ),
      )
  }
}

///|
/// Reject incomplete tool-call builders before delegating JSON assembly.
fn validate_oai_compat_stream_tool_calls(
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  for tc in acc.tool_calls {
    if tc.id == "" {
      raise @posoco.ModelError::ResponseParse(
        "openai-compatible SSE parse failure (stage=tool.id, category=missing)",
      )
    }
    if tc.name == "" {
      raise @posoco.ModelError::ResponseParse(
        "openai-compatible SSE parse failure (stage=tool.name, category=missing)",
      )
    }
    if tc.arguments_json == "" {
      raise @posoco.ModelError::ResponseParse(
        "openai-compatible SSE parse failure (stage=tool.arguments, category=missing)",
      )
    }
    let _ : Json = @json.parse(tc.arguments_json) catch {
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "openai-compatible SSE parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{tc.arguments_json.length()})",
        )
    }
  }
}
