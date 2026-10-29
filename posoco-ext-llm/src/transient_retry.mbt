///|
/// Router-level transient-failure retry policy. Applied by
/// `RouterModelPort::from_catalogs` to every ingested slot port so all
/// providers inherit the same exception-retry semantics (connection-stage
/// transport failures, sudden 5xx, mid-stream resets, truncated SSE) without
/// per-provider wrappers. Rate-limit (429) verdicts never retry here — they
/// belong to the rate-limit resume domain.
pub(all) struct TransientRetryPolicy {
  /// Retries granted after the first failure (total attempts = 1 + this).
  max_retries : Int32
  /// Delay before the first retry; later retries follow the fibonacci
  /// progression 1x, 2x, 3x, 5x, 8x, ... of this delay.
  initial_delay_ms : Int32
} derive(Debug)

///|
/// 1 initial attempt + up to 10 retries with fibonacci backoff of
/// 1, 2, 3, 5, 8, 13, 21, 34, 55, 89 seconds — up to ~231s of total waiting,
/// the Customer-approved trade-off for riding out network fluctuations
/// instead of failing the session.
pub fn TransientRetryPolicy::default() -> TransientRetryPolicy {
  { max_retries: 10, initial_delay_ms: 1000, }
}

///|
pub extend TransientRetryPolicy with @debug.Debug::{to_repr}

///|
/// Delay before retry number `retry_index` (0-based): the fibonacci
/// progression seeded at `initial_delay_ms` — 1x, 2x, 3x, 5x, 8x, ... of it.
pub fn TransientRetryPolicy::delay_ms(
  self : TransientRetryPolicy,
  retry_index : Int32,
) -> Int32 {
  let mut delay = self.initial_delay_ms
  let mut next = self.initial_delay_ms * 2
  let mut i = 0
  while i < retry_index {
    let stepped = delay + next
    delay = next
    next = stepped
    i += 1
  }
  delay
}

///|
/// Total time a fully-exhausted policy spends waiting between attempts.
pub fn TransientRetryPolicy::total_backoff_ms(
  self : TransientRetryPolicy,
) -> Int32 {
  let mut total = 0
  for i in 0..<self.max_retries {
    total += self.delay_ms(i)
  }
  total
}

///|
/// The final error after the retry budget is spent: re-wrapped in its own
/// variant (so downstream classification still sees the same shape) with an
/// explicit exhausted marker in front of the original message.
fn exhausted_retries_error(
  policy : TransientRetryPolicy,
  error : @posoco.ModelError,
) -> @posoco.ModelError {
  let marker = "transient retries exhausted after \{policy.max_retries} retries (total backoff \{policy.total_backoff_ms() / 1000}s): "
  match error {
    @posoco.ModelError::Transport(msg) =>
      @posoco.ModelError::Transport(marker + msg)
    @posoco.ModelError::ResponseParse(msg) =>
      @posoco.ModelError::ResponseParse(marker + msg)
    other => other
  }
}

///|
struct TransientRetryModelPort {
  inner : &@posoco.ModelPort
  policy : TransientRetryPolicy
}

///|
pub fn transient_retry_port(
  inner~ : &@posoco.ModelPort,
  policy~ : TransientRetryPolicy,
) -> &@posoco.ModelPort {
  TransientRetryModelPort::{ inner, policy, }
}

///|
/// Retryable classes, all leaving the request half-processed on a stateless
/// completion POST (streamed chunks already delivered to the host/UI are not
/// transcript fact, so repeating the request from scratch is safe):
/// classified by `@chatkit.is_transient_model_error` over the shared
/// provider message shapes.
pub impl @posoco.ModelPort for TransientRetryModelPort with fn chat(
  self : TransientRetryModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let mut retries_used = 0
  while true {
    let result = Ok(self.inner.chat(scope, messages, tools, options, stream)) catch {
      error => Err(error)
    }
    match result {
      Ok(value) => return value
      Err(error) =>
        if @chatkit.is_transient_model_error(error) {
          if retries_used >= self.policy.max_retries {
            raise exhausted_retries_error(self.policy, error)
          }
          @async.sleep(self.policy.delay_ms(retries_used))
          retries_used += 1
        } else {
          raise error
        }
    }
  }
  abort("transient retry loop exits via return or raise")
}

///|
/// Compact retries like any other completion POST: transient failures while
/// summarizing replay the summary request from scratch.
pub impl @posoco.ModelPort for TransientRetryModelPort with fn compact(
  self : TransientRetryModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let mut retries_used = 0
  while true {
    let result = Ok(
      self.inner.compact(scope, messages, tools, options, trigger),
    ) catch {
      error => Err(error)
    }
    match result {
      Ok(value) => return value
      Err(error) =>
        if @chatkit.is_transient_model_error(error) {
          if retries_used >= self.policy.max_retries {
            raise exhausted_retries_error(self.policy, error)
          }
          @async.sleep(self.policy.delay_ms(retries_used))
          retries_used += 1
        } else {
          raise error
        }
    }
  }
  abort("transient retry loop exits via return or raise")
}

///|
pub impl @posoco.ModelPort for TransientRetryModelPort with fn provider_config(
  self : TransientRetryModelPort,
) -> @posoco.ProviderConfig {
  self.inner.provider_config()
}

///|
pub extend TransientRetryModelPort with @posoco.ModelPort::{
  provider_config,
  chat,
  compact,
}
