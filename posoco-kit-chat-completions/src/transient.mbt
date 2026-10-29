///|
/// Transient-failure classification shared by every chat-completions
/// provider: the HTTP/SSE message shapes this kit's http_utils and SSE
/// processors produce. The router-level retry policy (posoco-ext-llm) keys
/// off this predicate, so a provider inherits retrying by emitting these
/// shapes — no per-provider retry wrapper.
///
/// Retryable:
/// - `ResponseParse` "SSE truncated" — marker-less stream EOF.
/// - `Transport` "stage=read_stream" — mid-stream connection reset.
/// - `Transport` "status=408" / "status=5xx" — gateway timeouts and 5xx.
/// - `Transport` without a `status=` marker — connection-establishment and
///   transfer-phase network noise (DNS resolution failures, connection
///   refused, connect/read timeouts, socket resets before a status exists),
///   unless the message marks a deterministic outcome
///   (`deterministic_transport`).
///
/// Never retryable: `RateLimited` (429 belongs to the rate-limit resume
/// domain), marked 401/403 and other deterministic 4xx, `RequestBuild`,
/// ordinary parse failures, provider-declared terminal failures
/// (`category=provider_error` / `category=not_completed` /
/// `stage=response.error`), client/URL construction failures
/// (`stage=create_client` / `stage=split_url`), and user-initiated
/// cancellations ("cancel"/"abort" in the transport detail).
pub fn is_transient_model_error(error : @posoco.ModelError) -> Bool {
  match error {
    @posoco.ModelError::ResponseParse(msg) => msg.contains("SSE truncated")
    @posoco.ModelError::Transport(msg) => transient_transport(msg)
    _ => false
  }
}

///|
/// Transport-verdict rules, most-specific first:
/// 1. mid-stream read resets stay retryable (existing contract),
/// 2. a parsed 408/5xx status marker is retryable (existing contract),
/// 3. any other marked status is a deterministic HTTP verdict — 429 and
///    4xx fail fast,
/// 4. unmarked transport failures are network noise and retry unless the
///    message marks a deterministic outcome.
fn transient_transport(msg : String) -> Bool {
  msg.contains("stage=read_stream") ||
  transient_status(msg) ||
  (unmarked_transport(msg) && !deterministic_transport(msg))
}

///|
/// An unmarked transport failure never saw an HTTP verdict: it failed while
/// connecting, sending, or reading — DNS resolution, connection refused,
/// connect/read timeouts, socket resets.
fn unmarked_transport(msg : String) -> Bool {
  !msg.contains("status=")
}

///|
/// Deterministic unmarked transport outcomes retrying cannot fix:
/// - provider-declared terminal failures (SSE error events,
///   `response.failed`/`response.incomplete`, structured API errors) are the
///   provider's answer, not network noise;
/// - client construction and URL shaping are configuration errors;
/// - user-initiated cancellations must never restart the turn (mirrors the
///   magpie guard: abort/cancel detail words mark an intentional stop).
fn deterministic_transport(msg : String) -> Bool {
  msg.contains("category=provider_error") ||
  msg.contains("category=not_completed") ||
  msg.contains("stage=response.error") ||
  msg.contains("stage=create_client") ||
  msg.contains("stage=split_url") ||
  cancellation_text(msg)
}

///|
fn cancellation_text(msg : String) -> Bool {
  let lower = msg.to_lower()
  lower.contains("cancel") || lower.contains("abort")
}

///|
/// Parse the `status=` marker of the shared `"(stage=…, status=NNN, …)"`
/// message shape and report whether the status is transiently retryable
/// (408 or 5xx). A malformed or absent marker returns false.
fn transient_status(msg : String) -> Bool {
  let marker = match msg.find("status=") {
    Some(offset) => offset + "status=".length()
    None => return false
  }
  let mut value = 0
  let mut count = 0
  let mut i = marker
  while i < msg.length() && count < 3 {
    let ch = msg[i]
    if ch >= '0' && ch <= '9' {
      value = value * 10 + (ch - '0').to_int()
      count = count + 1
      i = i + 1
    } else {
      break
    }
  }
  count == 3 && (value >= 500 || value == 408)
}
