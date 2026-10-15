///|
/// Native+wasm+js: the reset probe talks HTTP.
///
/// Typed rate-limit recovery for the Go plane. The shared wire layer
/// classifies 429/quota-phrased bodies into `ModelError::RateLimited`
/// already; what the Go plane adds is the reset time the error body often
/// omits: this decorator probes the authoritative `/usage` endpoint and
/// fills `reset_at_ms` from the window that is actually out — widest first
/// (monthly → weekly → 5-hour), because a monthly cap explains a refusal a
/// 5-hour window cannot. The host's rate-limit guard then schedules the
/// automatic recovery instead of guessing a backoff. A failed probe keeps
/// the original error (`reset_at_ms = None`), which the host treats with
/// its designed probing backoff — never a fabricated reset time.

///|
/// The window whose exhaustion best explains a refusal, widest first.
fn go_binding_reset(usage : GoUsage) -> Int64? {
  if usage.monthly.rate_limited {
    return usage.monthly.reset_at_ms
  }
  if usage.weekly.rate_limited {
    return usage.weekly.reset_at_ms
  }
  if usage.rolling.rate_limited {
    return usage.rolling.reset_at_ms
  }
  None
}

///|
/// One rate-limited verdict, enriched: a `RateLimited` without a reset time
/// gets one from the `/usage` probe when a window is verifiably out. Always
/// returns a `RateLimited` — the original or the enriched one; a failed
/// probe keeps the original untouched.
async fn go_enrich_rate_limit(
  base_url : String,
  api_key : String,
  info : @posoco.RateLimitInfo,
) -> @posoco.ModelError {
  match info.reset_at_ms {
    Some(_) => @posoco.ModelError::RateLimited(info)
    None =>
      match fetch_go_usage(base_url, api_key) {
        Ok(usage) =>
          match go_binding_reset(usage) {
            Some(reset_at_ms) =>
              @posoco.ModelError::RateLimited({
                ..info,
                reset_at_ms: Some(reset_at_ms),
              })
            None => @posoco.ModelError::RateLimited(info)
          }
        Err(_) => @posoco.ModelError::RateLimited(info)
      }
  }
}

///|
/// The Go rate-limit port: forwards everything to the shared wire port and
/// enriches rate-limit verdicts on the way out (chat and compact).
pub(all) struct GoRateLimitModelPort {
  inner : &@posoco.ModelPort
  base_url : String
  api_key : String
}

///|
pub fn GoRateLimitModelPort::GoRateLimitModelPort(
  inner~ : &@posoco.ModelPort,
  base_url~ : String,
  api_key~ : String,
) -> GoRateLimitModelPort {
  { inner, base_url, api_key, }
}

///|
pub impl @posoco.ModelPort for GoRateLimitModelPort with fn chat(
  self : GoRateLimitModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let result = Ok(self.inner.chat(scope, messages, tools, options, stream)) catch {
    error => Err(error)
  }
  match result {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
pub impl @posoco.ModelPort for GoRateLimitModelPort with fn compact(
  self : GoRateLimitModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let result = Ok(self.inner.compact(scope, messages, tools, options, trigger)) catch {
    error => Err(error)
  }
  match result {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
pub impl @posoco.ModelPort for GoRateLimitModelPort with fn provider_config(
  self : GoRateLimitModelPort,
) -> @posoco.ProviderConfig {
  self.inner.provider_config()
}

///|
pub extend GoRateLimitModelPort with @posoco.ModelPort::{
  provider_config,
  chat,
  compact,
}
