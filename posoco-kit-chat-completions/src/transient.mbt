///|
/// Transient-failure classification shared by every chat-completions
/// provider: the HTTP/SSE message shapes this kit's http_utils and SSE
/// processors produce. The router-level retry policy (posoco-ext-llm) keys
/// off this predicate, so a provider inherits retrying by emitting these
/// shapes — no per-provider retry wrapper.
///
/// Conservative by design: only enumerated shapes retry.
/// - `ResponseParse` "SSE truncated" — marker-less stream EOF.
/// - `Transport` "stage=read_stream" — mid-stream connection reset.
/// - `Transport` "status=408" / "status=5xx" — gateway timeouts and 5xx.
///
/// Never retryable: `RateLimited` (429 belongs to the rate-limit resume
/// domain), 401/403 (auth renewal domain), other 4xx, `RequestBuild`, and
/// unmarked `Transport` messages.
pub fn is_transient_model_error(error : @posoco.ModelError) -> Bool {
  match error {
    @posoco.ModelError::ResponseParse(msg) => msg.contains("SSE truncated")
    @posoco.ModelError::Transport(msg) =>
      msg.contains("stage=read_stream") || transient_status(msg)
    _ => false
  }
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
