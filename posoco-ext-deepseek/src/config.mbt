///|
/// Configuration for DeepSeekModelPort. Defaults target the standard
/// `https://api.deepseek.com` endpoint; FIM and prefix completion use the
/// `/beta` base_url variant.
pub(all) struct DeepSeekConfig {
  /// API key (DEEPSEEK environment variable by convention).
  api_key : String
  /// Base URL. Default: "https://api.deepseek.com".
  base_url : String
  /// Model id used for chat, FIM, and prefix completion. Defaults to the
  /// provider-owned `deepseek-flash`, so a credential alone composes a
  /// working catalog without any host settings.
  model : String
  /// Endpoint path prefix, e.g. "/v1" when base_url is "http://host:port".
  endpoint_prefix : String
  /// Provider-owned reasoning effort. Passed through verbatim; DeepSeek's
  /// server maps the requested effort level itself. The empty string means
  /// thinking is off; every other value must be on the uniform ladder from
  /// `deepseek_reasoning_efforts`.
  reasoning_effort : String
  /// Token budget ceiling reported to the host so auto-compact can size
  /// itself. None leaves auto-compact disabled — an unknown window is never
  /// guessed (the /models endpoint carries no context length).
  context_window : Int32?
  /// Streamed reasoning ceiling: default 120000 characters; None disables it.
  max_reasoning_chars : Int32?
  /// Retry once at low effort on a non-stream reasoning-only length cutoff.
  /// Enabled by default; false disables retries.
  recover_on_reasoning_exhaustion : Bool
  /// Exact repeated reasoning suffix span: default 256; None disables it.
  repeated_reasoning_span_chars : Int32?
  /// When true, image blocks encode as typed `image_url` content parts
  /// instead of placeholder downgrades and the model slot advertises
  /// `image_in`. Opt-in via the `image_input` setting: the /models endpoint
  /// carries no modality metadata, so the host declares image capability.
  supports_images : Bool
  /// Explicit reference renderer version; unknown avoids inferring support
  /// from mutable hosted model aliases.
  prompt_profile : String
} derive(Eq, Debug)

///|
pub extend DeepSeekConfig with Eq::{not_equal, equal}

///|
pub extend DeepSeekConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DeepSeekConfig::DeepSeekConfig(
  api_key : String,
  model~ : String = "deepseek-flash",
  base_url~ : String = "https://api.deepseek.com",
  endpoint_prefix~ : String = "",
  reasoning_effort~ : String = "high",
  context_window~ : Int32? = None,
  max_reasoning_chars~ : Int32? = Some(120000),
  recover_on_reasoning_exhaustion~ : Bool = true,
  repeated_reasoning_span_chars~ : Int32? = Some(256),
  supports_images~ : Bool = false,
  prompt_profile~ : String = "unknown",
) -> DeepSeekConfig {
  if prompt_profile != "unknown" && prompt_profile != "v4" &&
    prompt_profile != "v4.1" {
    abort("posoco-ext-deepseek: unsupported prompt_profile: " + prompt_profile)
  }
  if prompt_profile == "v4" && supports_images {
    abort("posoco-ext-deepseek: V4 renderer cannot accept image input")
  }
  if reasoning_effort != "" &&
    !deepseek_reasoning_efforts().contains(reasoning_effort) {
    abort(
      "posoco-ext-deepseek: unsupported reasoning effort: " + reasoning_effort,
    )
  }
  match context_window {
    Some(n) =>
      if n <= 0 {
        abort("posoco-ext-deepseek: context_window must be positive")
      }
    None => ()
  }
  match max_reasoning_chars {
    Some(n) =>
      if n <= 0 {
        abort("posoco-ext-deepseek: max_reasoning_chars must be positive")
      }
    None => ()
  }
  match repeated_reasoning_span_chars {
    Some(n) =>
      if n < 128 || n > 715827882 {
        abort(
          "posoco-ext-deepseek: repeated_reasoning_span_chars must be between 128 and 715827882",
        )
      }
    None => ()
  }
  {
    api_key,
    base_url,
    model,
    endpoint_prefix,
    reasoning_effort,
    context_window,
    max_reasoning_chars,
    recover_on_reasoning_exhaustion,
    repeated_reasoning_span_chars,
    supports_images,
    prompt_profile,
  }
}

///|
/// Rebuild a provider config with a validated effort value. The picker-facing
/// "off" entry maps to "" (thinking disabled on the wire); any other value
/// must be on the uniform provider ladder.
pub fn DeepSeekConfig::with_reasoning_effort(
  self : DeepSeekConfig,
  effort : String,
) -> DeepSeekConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, reasoning_effort: "", }
  }
  if !deepseek_reasoning_efforts().contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_deepseek",
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, reasoning_effort: effort, }
}

///|
pub(all) struct DeepSeekModelPort {
  config : DeepSeekConfig
  ctx : @devkit.ExtContext
}

///|
pub fn DeepSeekModelPort::DeepSeekModelPort(
  config : DeepSeekConfig,
  ctx~ : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> DeepSeekModelPort {
  { config, ctx, }
}
