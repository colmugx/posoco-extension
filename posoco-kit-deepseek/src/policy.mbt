///|
/// The client-side half of DeepSeek's serving contract.
///
/// DeepSeek's serving engine treats a conversation as an append-only token
/// stream: a byte-stable prefix is reused from the shared KV cache, and only
/// the newest suffix runs through prefill. That property is what makes an
/// agent turn cheap, and it is also what makes two failure modes expensive —
/// a prefix that churns, and a decode that never converges. The rules in this
/// package are the client's obligations toward that engine, not generic model
/// guardrails; every rule is DeepSeek-specific.
///
/// These three limits are the only knobs. The remaining rules (canonical tool
/// order, tail convergence guidance, request-aware reasoning replay) are not
/// configurable here: they are what keeps the prefix stable and the decode
/// bounded, so `deepseek_policy_port` always applies them.
pub(all) struct DeepSeekPolicy {
  /// Fail-closed ceiling on accumulated streamed reasoning characters. Not a
  /// token budget; `None` disables the guard.
  max_reasoning_chars : Int32?
  /// Exact repeated reasoning suffix span, in characters. `None` disables the
  /// collapse guard. The detector needs at least 128 characters.
  repeated_reasoning_span_chars : Int32?
  /// Retry a non-streaming response once at low effort when it stopped at
  /// length with no answer text and no tool calls.
  recover_on_reasoning_exhaustion : Bool
} derive(Eq, Debug)

///|
pub extend DeepSeekPolicy with Eq::{not_equal, equal}

///|
pub extend DeepSeekPolicy with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Conservative defaults: a generous reasoning ceiling, the narrowest useful
/// collapse span, and a single bounded recovery attempt. These are the same
/// values a host that only supplies a credential gets.
pub fn DeepSeekPolicy::default_protections() -> DeepSeekPolicy {
  {
    max_reasoning_chars: Some(120000),
    repeated_reasoning_span_chars: Some(256),
    recover_on_reasoning_exhaustion: true,
  }
}

///|
/// No limits: the rules that keep the prefix stable still apply, but a stream
/// is never cut short and a length cutoff is never retried.
pub fn DeepSeekPolicy::disabled() -> DeepSeekPolicy {
  {
    max_reasoning_chars: None,
    repeated_reasoning_span_chars: None,
    recover_on_reasoning_exhaustion: false,
  }
}

///|
pub fn DeepSeekPolicy::DeepSeekPolicy(
  max_reasoning_chars~ : Int32?,
  repeated_reasoning_span_chars~ : Int32?,
  recover_on_reasoning_exhaustion~ : Bool,
) -> DeepSeekPolicy {
  {
    max_reasoning_chars,
    repeated_reasoning_span_chars,
    recover_on_reasoning_exhaustion,
  }
}

///|
/// Resolve the policy from a provider settings object. Both planes use the
/// same key names, so one host configuration describes the DeepSeek contract
/// whichever endpoint serves the model:
///
/// - `max_reasoning_chars`: positive integer, or `null` to disable
/// - `repeated_reasoning_span_chars`: integer 128..715827882, or `null`
/// - `recover_on_reasoning_exhaustion`: boolean
///
/// Absent keys inherit `defaults`. Malformed values are typed composition
/// failures under the caller's `manifest_id` — never a silent fallback.
pub fn DeepSeekPolicy::from_settings(
  settings : Json?,
  manifest_id~ : String,
  defaults~ : DeepSeekPolicy = DeepSeekPolicy::default_protections(),
) -> DeepSeekPolicy raise @posoco.CompositionError {
  let fields : Map[String, Json] = match settings {
    None => Map::from_array([])
    Some(Json::Object(fields)) => fields
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id~,
        detail="provider settings must be a JSON object",
      )
  }
  let max_reasoning_chars = match fields.get("max_reasoning_chars") {
    None => defaults.max_reasoning_chars
    Some(Json::Null) => None
    Some(Json::Number(number, ..)) => {
      if number.is_nan() ||
        number.is_inf() ||
        number <= 0.0 ||
        number > 2147483647.0 ||
        number.to_int().to_double() != number {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id~,
          detail="max_reasoning_chars must be a positive integer within Int range",
        )
      }
      Some(number.to_int())
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id~,
        detail="max_reasoning_chars must be a positive integer within Int range",
      )
  }
  let repeated_reasoning_span_chars = match
    fields.get("repeated_reasoning_span_chars") {
    None => defaults.repeated_reasoning_span_chars
    Some(Json::Null) => None
    Some(Json::Number(number, ..)) => {
      if number.is_nan() ||
        number.is_inf() ||
        number < 128.0 ||
        number > 715827882.0 ||
        number.to_int().to_double() != number {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id~,
          detail="repeated_reasoning_span_chars must be an integer from 128 to 715827882",
        )
      }
      Some(number.to_int())
    }
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id~,
        detail="repeated_reasoning_span_chars must be an integer from 128 to 715827882",
      )
  }
  let recover_on_reasoning_exhaustion = match
    fields.get("recover_on_reasoning_exhaustion") {
    None => defaults.recover_on_reasoning_exhaustion
    Some(Json::True) => true
    Some(Json::False) => false
    Some(_) =>
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id~,
        detail="recover_on_reasoning_exhaustion must be a boolean",
      )
  }
  {
    max_reasoning_chars,
    repeated_reasoning_span_chars,
    recover_on_reasoning_exhaustion,
  }
}
