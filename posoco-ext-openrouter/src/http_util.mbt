///|
/// Shared HTTP utilities for the OpenRouter adapter — error body capture,
/// status classification (with the `error.metadata.error_type` vocabulary),
/// stream termination classification, and tool-call validation. All items are
/// package-visible so they can be used across files in this package
/// (openrouter.mbt, chat_native_js.mbt, compact_native_js.mbt, tests). Pure
/// functions only: nothing here touches `@http`, so the file compiles on every
/// backend. The header readers live with the chat driver.

///|
/// Non-2xx body capture. The provider's error body is the primary diagnostic
/// for an HTTP failure — it names the rejected field and the expected shape —
/// so UTF-8 text is carried into the error message (capped at
/// `openrouter_error_body_cap` chars). Only undecodable or unreadable bodies
/// degrade to bare metadata.
priv enum OpenRouterErrorBody {
  BodyText(String)
  BodyBytesInvalidUtf8(Int)
  BodyReadFailed
  BodyUnavailable
}

///|
/// Upper bound for the provider error body embedded in an error message.
let openrouter_error_body_cap : Int = 2048

///|
/// Cap an error body for the message. Char-wise copy keeps the cut on a
/// Unicode boundary (String slicing can raise on surrogate edges).
fn cap_openrouter_error_body(text : String) -> String {
  if text.length() <= openrouter_error_body_cap {
    text
  } else {
    let sb = StringBuilder::new()
    let mut count = 0
    for c in text {
      if count >= openrouter_error_body_cap {
        break
      }
      sb.write_char(c)
      count += 1
    }
    sb.to_string() + "...(truncated, body_chars=\{text.length()})"
  }
}

///|
/// Extract the `error.metadata.error_type` label from an OpenRouter error
/// body (`{error:{code,message,metadata:{error_type}}}`). Only a sanitized,
/// enum-like label (see `sanitize_error_label` in sse.mbt) crosses the
/// boundary — never free text — so no prompt/request content can ride along.
fn openrouter_error_type(body_text : String) -> String? {
  let body : Json = @json.parse(body_text) catch { _ => return None }
  guard body is Object(root) else { return None }
  match root.get("error") {
    Some(Object(err)) =>
      match err.get("metadata") {
        Some(Object(metadata)) =>
          match metadata.get("error_type") {
            Some(String(t)) => sanitize_error_label(t)
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Format an HTTP failure, embedding the provider's error body verbatim
/// (capped) whenever it drained as UTF-8 text. The stable `error_type` label
/// is preferred over the bare HTTP code as the failure's identity.
fn format_openrouter_http_error(
  stage : String,
  status : Int,
  body : OpenRouterErrorBody,
  error_type? : String? = None,
) -> String {
  let detail = match body {
    BodyText(text) => "body=\{cap_openrouter_error_body(text)}"
    BodyBytesInvalidUtf8(length) =>
      "body_bytes=\{length}, body_category=invalid_utf8"
    BodyReadFailed => "body_category=read_failed"
    BodyUnavailable => "body_category=unavailable"
  }
  let type_label = match error_type {
    Some(t) => ", error_type=\{t}"
    None => ""
  }
  "openrouter HTTP error (stage=\{stage}, status=\{status}\{type_label}, \{detail})"
}

///|
/// Format a 402 / payment_required verdict: out-of-credits, not a transport
/// fault. The message names the semantics explicitly so a host can surface
/// "top up credits" instead of a generic retry loop.
fn format_openrouter_payment_error(
  stage : String,
  status : Int,
  body : OpenRouterErrorBody,
  error_type? : String? = None,
) -> String {
  format_openrouter_http_error(stage, status, body, error_type~) +
  ", category=payment_required (insufficient credits; add credits at https://openrouter.ai/credits)"
}

///|
fn is_openrouter_http_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
/// `X-RateLimit-Reset` carries the reset as absolute epoch seconds. Bounded
/// to year 2100 so garbage digits never fabricate a schedulable reset.
fn openrouter_epoch_seconds_ms(value : String) -> Int64? {
  let trimmed = value.trim().to_owned()
  if trimmed.length() == 0 || trimmed.length() > 11 {
    return None
  }
  let mut secs : Int64 = 0L
  for i in 0..<trimmed.length() {
    let c = trimmed[i]
    if c < '0' || c > '9' {
      return None
    }
    secs = secs * 10L + (c - '0').to_int64()
  }
  if secs >= 0L && secs <= 4102444800L {
    Some(secs * 1000L)
  } else {
    None
  }
}

///|
/// Pure HTTP-status classifier. A captured provider body is carried through
/// to the observable error message so a 400 says why it is a 400, prefixed by
/// the stable `error.metadata.error_type` label when OpenRouter stated one.
/// Dispatch, mirroring the wire contract:
/// - 402 (or any status labeled `payment_required`) is an out-of-credits
///   verdict raised as Transport with explicit payment/credits semantics.
/// - 429 is a quota verdict: the kit classifier parses the body's stated reset
///   time and raises the typed `RateLimited`; the caller passes the
///   `Retry-After` header (delta seconds or timestamp, parsed by the kit) and
///   `X-RateLimit-Reset` (epoch seconds, parsed here) as fallbacks when the
///   body stated no schedulable reset.
/// - every other non-2xx is Transport with the formatted body.
fn classify_openrouter_http_status(
  stage : String,
  status : Int,
  body : OpenRouterErrorBody,
  now_ms~ : Int64,
  retry_after_header? : String? = None,
  rate_limit_reset_header? : String? = None,
) -> @posoco.ModelError? {
  if is_openrouter_http_success(status) {
    return None
  }
  let body_text = match body {
    BodyText(text) => text
    _ => ""
  }
  let error_type = openrouter_error_type(body_text)
  if status == 402 || error_type == Some("payment_required") {
    return Some(
      @posoco.ModelError::Transport(
        format_openrouter_payment_error(stage, status, body, error_type~),
      ),
    )
  }
  if status == 429 {
    let verdict = @chatkit.classify_chat_completions_http_error(
      status,
      body_text,
      retry_after_header~,
      now_ms~,
    )
    match verdict {
      Some(@posoco.ModelError::RateLimited(info)) => {
        let with_reset = match info.reset_at_ms {
          Some(_) => info
          None =>
            match rate_limit_reset_header {
              Some(value) =>
                match openrouter_epoch_seconds_ms(value) {
                  Some(ms) => { ..info, reset_at_ms: Some(ms) }
                  None => info
                }
              None => info
            }
        }
        // The stable error_type label names the verdict better than the bare
        // provider code (e.g. "rate_limit_exceeded" over a numeric code).
        let with_code = match error_type {
          Some(t) => { ..with_reset, provider_code: Some(t) }
          None => with_reset
        }
        return Some(@posoco.ModelError::RateLimited(with_code))
      }
      Some(err) => return Some(err)
      None => ()
    }
  }
  Some(
    @posoco.ModelError::Transport(
      format_openrouter_http_error(stage, status, body, error_type~),
    ),
  )
}

///|
/// `read_error_body` and the header readers (the functions that take an
/// `@http.Client` / `@http.Response`) live in chat_native_js.mbt, co-located
/// with the chat impl. The classification helpers below are pure and stay
/// here for every backend.

///|
/// Pure classification for stream termination; used by the HTTP loop and
/// offline tests so EOF is never inferred from accumulated content.
priv enum OpenRouterStreamTermination {
  ExplicitTerminal
  CleanEof
  TransportFailure
}

///|
fn classify_openrouter_stream_termination(
  termination : OpenRouterStreamTermination,
) -> @posoco.ModelError? {
  match termination {
    ExplicitTerminal => None
    CleanEof =>
      Some(
        @posoco.ModelError::ResponseParse(
          "openrouter SSE truncated (stage=eof, terminal_marker=missing)",
        ),
      )
    TransportFailure =>
      Some(
        @posoco.ModelError::Transport(
          "openrouter transport failure (stage=read_stream)",
        ),
      )
  }
}

///|
/// Whether a marker-less EOF is tolerable: at least one accumulated tool call
/// and every one of them complete (id/name/parseable arguments — a stream cut
/// mid-arguments fails JSON validation). Proxied routes occasionally close
/// after the last delta but before finish_reason/[DONE]; what the model
/// verifiably requested is then intact. Text-only truncations stay loud: a
/// cut answer must not pass as complete.
fn openrouter_eof_tolerable(acc : @posoco.StreamAccumulator) -> Bool {
  if acc.tool_calls.length() == 0 {
    return false
  }
  let result = Ok(validate_openrouter_stream_tool_calls(acc)) catch {
    e => Err(e)
  }
  result is Ok(_)
}

///|
/// Reject incomplete tool-call builders before delegating JSON assembly.
fn validate_openrouter_stream_tool_calls(
  acc : @posoco.StreamAccumulator,
) -> Unit raise @posoco.ModelError {
  for tc in acc.tool_calls {
    if tc.id == "" {
      raise @posoco.ModelError::ResponseParse(
        "openrouter SSE parse failure (stage=tool.id, category=missing)",
      )
    }
    if tc.name == "" {
      raise @posoco.ModelError::ResponseParse(
        "openrouter SSE parse failure (stage=tool.name, category=missing)",
      )
    }
    if tc.arguments_json == "" {
      raise @posoco.ModelError::ResponseParse(
        "openrouter SSE parse failure (stage=tool.arguments, category=missing)",
      )
    }
    let _ : Json = @json.parse(tc.arguments_json) catch {
      _ =>
        raise @posoco.ModelError::ResponseParse(
          "openrouter SSE parse failure (stage=tool.arguments_json, category=malformed, payload_chars=\{tc.arguments_json.length()})",
        )
    }
  }
}
