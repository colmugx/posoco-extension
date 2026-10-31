///|
/// http_util.mbt — protocol-neutral HTTP failure classification.
///
/// The provider's error body is the primary diagnostic for an HTTP failure —
/// it names the rejected field and the expected shape — so UTF-8 text is
/// carried into the error message (capped). Only undecodable or unreadable
/// bodies degrade to bare metadata. Callers prefix the stage with the wire id
/// (`chat.http_status`, `messages.http_status`, ...) so a wrong `protocol`
/// setting is visible in the failure itself.

///|
priv enum CustomErrorBody {
  BodyText(String)
  BodyBytesInvalidUtf8(Int32)
  BodyReadFailed
  BodyUnavailable
} derive(Eq, Debug)

///|
extend CustomErrorBody with Eq::{not_equal, equal}

///|
extend CustomErrorBody with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Upper bound for the provider error body embedded in an error message.
let custom_error_body_cap : Int32 = 2048

///|
/// Char-wise copy keeps the cut on a Unicode boundary (String slicing can
/// raise on surrogate edges).
fn cap_custom_error_body(text : String) -> String {
  if text.length() <= custom_error_body_cap {
    text
  } else {
    let sb = StringBuilder()
    let mut count = 0
    for c in text {
      if count >= custom_error_body_cap {
        break
      }
      sb.write_char(c)
      count += 1
    }
    sb.to_string() + "...(truncated, body_chars=\{text.length()})"
  }
}

///|
fn format_custom_http_error(
  stage : String,
  status : Int32,
  body : CustomErrorBody,
) -> String {
  let detail = match body {
    BodyText(text) => "body=\{cap_custom_error_body(text)}"
    BodyBytesInvalidUtf8(length) =>
      "body_bytes=\{length}, body_category=invalid_utf8"
    BodyReadFailed => "body_category=read_failed"
    BodyUnavailable => "body_category=unavailable"
  }
  "custom provider HTTP error (stage=\{stage}, status=\{status}, \{detail})"
}

///|
fn is_custom_http_success(status : Int32) -> Bool {
  status >= 200 && status < 300
}

///|
/// Pure HTTP-status classifier. A captured provider body is carried through to
/// the observable error message so a 400 says why it is a 400. A 429 is a
/// quota verdict: the body is parsed by the shared rate-limit kit for a stated
/// reset time and raised as the typed `RateLimited`.
fn classify_custom_http_status(
  stage : String,
  status : Int32,
  body : CustomErrorBody,
  now_ms~ : Int64,
) -> @posoco.ModelError? {
  if is_custom_http_success(status) {
    return None
  }
  if status == 429 {
    let body_text = match body {
      BodyText(text) => text
      _ => ""
    }
    let verdict = @ratelimit.classify_rate_limit_error(
      status,
      body_text,
      now_ms~,
    )
    match verdict {
      Some(err) => return Some(err)
      None => ()
    }
  }
  Some(
    @posoco.ModelError::Transport(format_custom_http_error(stage, status, body)),
  )
}

///|
/// Used by the HTTP loops and offline tests so EOF is never inferred from
/// accumulated content. `wire` names the dialect in the raised message.
priv enum CustomStreamTermination {
  ExplicitTerminal
  CleanEof
  TransportFailure
} derive(Eq, Debug)

///|
extend CustomStreamTermination with Eq::{not_equal, equal}

///|
extend CustomStreamTermination with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn classify_custom_stream_termination(
  wire~ : String,
  termination : CustomStreamTermination,
) -> @posoco.ModelError? {
  match termination {
    ExplicitTerminal => None
    CleanEof =>
      Some(
        @posoco.ModelError::ResponseParse(
          "custom provider SSE truncated (stage=eof, wire=" +
          wire +
          ", terminal_marker=missing)",
        ),
      )
    TransportFailure =>
      Some(
        @posoco.ModelError::Transport(
          "custom provider transport failure (stage=read_stream, wire=" +
          wire +
          ")",
        ),
      )
  }
}

///|
/// Whether a marker-less EOF is tolerable on the chat-completions wire: at
/// least one accumulated tool call and every one of them complete (id/name/
/// parseable arguments — a stream cut mid-arguments fails JSON validation).
/// Proxied gateways occasionally close after the last delta but before
/// finish_reason/[DONE]; what the model verifiably requested is then intact.
/// Text-only truncations stay loud: a cut answer must not pass as complete.
fn custom_chat_eof_tolerable(
  acc : @posoco.StreamAccumulator,
) -> Bool raise @posoco.ModelError {
  let completion = acc.to_completion() catch {
    @posoco.ModelError::ResponseParse(_) => return false
    error => raise error
  }
  completion.has_tool_calls()
}

///|
fn validate_custom_chat_stream_tool_calls(
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  let _ = acc.to_completion() catch {
    @posoco.ModelError::ResponseParse(message) =>
      raise @posoco.ModelError::ResponseParse(
        "custom provider SSE parse failure (stage=tool_calls, wire=chat_completions): " +
        message,
      )
    error => raise error
  }
}
