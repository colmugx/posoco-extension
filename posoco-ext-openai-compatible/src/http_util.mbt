///|
/// Non-2xx body capture. The provider's error body is the primary diagnostic
/// for an HTTP failure — it names the rejected field and the expected shape —
/// so UTF-8 text is carried into the error message (capped at
/// `oai_compat_error_body_cap` chars). Only undecodable or unreadable bodies
/// degrade to bare metadata.
priv enum OaiCompatErrorBody {
  BodyText(String)
  BodyBytesInvalidUtf8(Int)
  BodyReadFailed
  BodyUnavailable
}

///|
/// Upper bound for the provider error body embedded in an error message.
let oai_compat_error_body_cap : Int = 2048

///|
/// Char-wise copy keeps the cut on a Unicode boundary (String slicing can
/// raise on surrogate edges).
fn cap_oai_compat_error_body(text : String) -> String {
  if text.length() <= oai_compat_error_body_cap {
    text
  } else {
    let sb = StringBuilder()
    let mut count = 0
    for c in text {
      if count >= oai_compat_error_body_cap {
        break
      }
      sb.write_char(c)
      count += 1
    }
    sb.to_string() + "...(truncated, body_chars=\{text.length()})"
  }
}

///|
fn format_oai_compat_http_error(
  stage : String,
  status : Int,
  body : OaiCompatErrorBody,
) -> String {
  let detail = match body {
    BodyText(text) => "body=\{cap_oai_compat_error_body(text)}"
    BodyBytesInvalidUtf8(length) =>
      "body_bytes=\{length}, body_category=invalid_utf8"
    BodyReadFailed => "body_category=read_failed"
    BodyUnavailable => "body_category=unavailable"
  }
  "openai-compatible HTTP error (stage=\{stage}, status=\{status}, \{detail})"
}

///|
fn is_oai_compat_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// Pure HTTP-status classifier. A captured provider body is carried through
/// to the observable error message so a 400 says why it is a 400. A 429 is a
/// quota verdict: the body is parsed for a stated reset time
/// (`resets_at`/`resets_in_seconds`, `retry_after`, or a timestamp inside
/// the message text) and raised as the typed `RateLimited`.
fn classify_oai_compat_http_status(
  stage : String,
  status : Int,
  body : OaiCompatErrorBody,
  now_ms~ : Int64,
) -> @posoco.ModelError? {
  if is_oai_compat_http_success(status) {
    return None
  }
  if status == 429 {
    let body_text = match body {
      BodyText(text) => text
      _ => ""
    }
    let verdict = @chatkit.classify_chat_completions_http_error(
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
    @posoco.ModelError::Transport(
      format_oai_compat_http_error(stage, status, body),
    ),
  )
}

///|
/// Used by the HTTP loop and offline tests so EOF is never inferred from
/// accumulated content.
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
/// Whether a marker-less EOF is tolerable: at least one accumulated tool call
/// and every one of them complete (id/name/parseable arguments — a stream cut
/// mid-arguments fails JSON validation). Proxied gateways (opencode-zen behind
/// Cloudflare) occasionally close after the last delta but before
/// finish_reason/[DONE]; what the model verifiably requested is then intact.
/// Text-only truncations stay loud: a cut answer must not pass as complete.
fn oai_compat_eof_tolerable(
  acc : @posoco.StreamAccumulator,
) -> Bool raise @posoco.ModelError {
  let completion = acc.to_completion() catch {
    @posoco.ModelError::ResponseParse(_) => return false
    error => raise error
  }
  completion.has_tool_calls()
}

///|
fn validate_oai_compat_stream_tool_calls(
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  let _ = acc.to_completion() catch {
    @posoco.ModelError::ResponseParse(message) =>
      raise @posoco.ModelError::ResponseParse(
        "openai-compatible SSE parse failure (stage=tool_calls): " + message,
      )
    error => raise error
  }
}
