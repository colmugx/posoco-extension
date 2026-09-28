///|
/// Router-level transient-failure retry policy. Applied by
/// `RouterModelPort::from_catalogs` to every ingested slot port so all
/// providers inherit the same exception-retry semantics (sudden 5xx, mid-stream
/// resets, truncated SSE) without per-provider wrappers. Rate-limit (429)
/// verdicts never retry here — they belong to the rate-limit resume domain.
pub(all) struct TransientRetryPolicy {
  /// Retries granted after the first failure (total attempts = 1 + this).
  max_retries : Int
  initial_delay_ms : Int
} derive(Debug)

///|
/// Mirrors the OpenCode session retry: 3 retries, 2s initial doubling delay.
pub fn TransientRetryPolicy::default() -> TransientRetryPolicy {
  { max_retries: 3, initial_delay_ms: 2000, }
}

///|
pub extend TransientRetryPolicy with @debug.Debug::{to_repr}

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
  let mut retries_left = self.policy.max_retries
  let mut delay_ms = self.policy.initial_delay_ms
  while true {
    let result = Ok(self.inner.chat(scope, messages, tools, options, stream)) catch {
      error => Err(error)
    }
    match result {
      Ok(value) => return value
      Err(error) =>
        if retries_left > 0 && @chatkit.is_transient_model_error(error) {
          @async.sleep(delay_ms)
          retries_left -= 1
          delay_ms *= 2
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
  options : @posoco.ChatOptions,
  trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let mut retries_left = self.policy.max_retries
  let mut delay_ms = self.policy.initial_delay_ms
  while true {
    let result = Ok(self.inner.compact(scope, messages, options, trigger)) catch {
      error => Err(error)
    }
    match result {
      Ok(value) => return value
      Err(error) =>
        if retries_left > 0 && @chatkit.is_transient_model_error(error) {
          @async.sleep(delay_ms)
          retries_left -= 1
          delay_ms *= 2
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
