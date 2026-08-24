///|
/// ModelPort decorator that retries Zen's transient failures.
///
/// Retried classes, all leaving the request half-processed on a stateless
/// completion POST (streamed chunks are a host/UI concern, not transcript
/// fact, so repeating the request from scratch is safe):
///
/// - marker-less EOF truncation (`ResponseParse("... SSE truncated ...")`) —
///   some Zen models close the stream without finish_reason / [DONE];
/// - mid-stream connection resets (`Transport("... stage=read_stream ...")`);
/// - gateway 503s (`Transport("... status=503 ...")`) — the Zen gateway
///   occasionally answers 503 under load, the same transient class pi retries.
///
/// Backoff mirrors OpenCode's session retry: 2s initial, doubling per retry.
struct ZenRetryModelPort {
  inner : &@posoco.ModelPort
  max_retries : Int
  initial_delay_ms : Int
}

///|
/// Retries granted after the first failure (total attempts = 1 + this).
let zen_max_retries : Int = 3

///|
/// OpenCode RETRY_INITIAL_DELAY.
let zen_retry_initial_delay_ms : Int = 2000

///|
fn zen_retry_port(inner : &@posoco.ModelPort) -> &@posoco.ModelPort {
  ZenRetryModelPort::{
    inner,
    max_retries: zen_max_retries,
    initial_delay_ms: zen_retry_initial_delay_ms,
  }
}

///|
fn zen_retryable_error(error : @posoco.ModelError) -> Bool {
  match error {
    @posoco.ModelError::ResponseParse(msg) => msg.contains("SSE truncated")
    @posoco.ModelError::Transport(msg) =>
      msg.contains("stage=read_stream") || msg.contains("status=503")
    _ => false
  }
}

///|
pub impl @posoco.ModelPort for ZenRetryModelPort with fn chat(
  self : ZenRetryModelPort,
  scope : @posoco.InvocationScope,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let mut retries_left = self.max_retries
  let mut delay_ms = self.initial_delay_ms
  while true {
    let result = Ok(self.inner.chat(scope, messages, tools, options, stream)) catch {
      error => Err(error)
    }
    match result {
      Ok(value) => return value
      Err(error) =>
        if retries_left > 0 && zen_retryable_error(error) {
          @async.sleep(delay_ms) catch {
            _ => ()
          }
          retries_left -= 1
          delay_ms *= 2
        } else {
          raise error
        }
    }
  }
  abort("zen retry loop exits via return or raise")
}

///|
pub impl @posoco.ModelPort for ZenRetryModelPort with fn compact(
  self : ZenRetryModelPort,
  scope : @posoco.InvocationScope,
  messages : Array[@posoco.Message],
  options : @posoco.ChatOptions,
  trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let mut retries_left = self.max_retries
  let mut delay_ms = self.initial_delay_ms
  while true {
    let result = Ok(self.inner.compact(scope, messages, options, trigger)) catch {
      error => Err(error)
    }
    match result {
      Ok(value) => return value
      Err(error) =>
        if retries_left > 0 && zen_retryable_error(error) {
          @async.sleep(delay_ms) catch {
            _ => ()
          }
          retries_left -= 1
          delay_ms *= 2
        } else {
          raise error
        }
    }
  }
  abort("zen retry loop exits via return or raise")
}

///|
pub impl @posoco.ModelPort for ZenRetryModelPort with fn provider_config(
  self : ZenRetryModelPort,
) -> @posoco.ProviderConfig {
  self.inner.provider_config()
}
