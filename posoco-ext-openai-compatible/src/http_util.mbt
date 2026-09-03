///|
/// Shared HTTP utilities for the OpenAI-compatible adapter — error body
/// capture, status classification, stream termination classification, and
/// tool-call validation. All items are package-visible so they can be used
/// across files in this package (openai_compatible.mbt, sse.mbt, tests).

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
/// Cap an error body for the message. Char-wise copy keeps the cut on a
/// Unicode boundary (String slicing can raise on surrogate edges).
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
/// Format an HTTP failure, embedding the provider's error body verbatim
/// (capped) whenever it drained as UTF-8 text.
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
/// `read_error_body` (the one function that takes an `@http.Client`)
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
/// Whether a marker-less EOF is tolerable: at least one accumulated tool call
/// and every one of them complete (id/name/parseable arguments — a stream cut
/// mid-arguments fails JSON validation). Proxied gateways (opencode-zen behind
/// Cloudflare) occasionally close after the last delta but before
/// finish_reason/[DONE]; what the model verifiably requested is then intact.
/// Text-only truncations stay loud: a cut answer must not pass as complete.
fn oai_compat_eof_tolerable(acc : @posoco.StreamAccumulator) -> Bool {
  if acc.tool_calls.length() == 0 {
    return false
  }
  let result = Ok(validate_oai_compat_stream_tool_calls(acc)) catch {
    e => Err(e)
  }
  result is Ok(_)
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
    if tc.arguments_json() == "" {
      raise @posoco.ModelError::ResponseParse(
        "openai-compatible SSE parse failure (stage=tool.arguments, category=missing)",
      )
    }
    let _ : Json = @json.parse(tc.arguments_json()) catch {
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "openai-compatible SSE parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{tc.arguments_json().length()})",
        )
    }
  }
}
