///|
/// DeepSeek-specific thinking effort tiers. DeepSeek's reasoning is binary
/// (on via deepseek-reasoner / off via deepseek-chat), but the reasoner model
/// accepts an effort hint. posoco's ReasoningEffort maps onto this; this enum
/// lets a caller override with provider-native granularity.
pub(all) enum ThinkingMode {
  No
  High
  Max
} derive(Eq, Debug)

///|
/// Configuration for DeepSeekModelPort. Defaults target the standard
/// `https://api.deepseek.com` endpoint; FIM and prefix completion use the
/// `/beta` base_url variant.
pub(all) struct DeepSeekConfig {
  /// API key (DEEPSEEK environment variable by convention).
  api_key : String
  /// Base URL. Default: "https://api.deepseek.com".
  base_url : String
  /// Chat completions model. Default: "deepseek-chat".
  chat_model : String
  /// Reasoner model (for ReasoningEffort != Off). Default: "deepseek-reasoner".
  reasoner_model : String
  /// Coder model for FIM. Default: "deepseek-coder".
  coder_model : String
  /// Provider-native thinking effort override. Applied when ChatOptions
  /// does not specify reasoning_effort.
  thinking : ThinkingMode
  /// Max retry attempts on transient HTTP errors. Default: 3.
  retry_attempts : Int
  /// Backoff in ms between retries. Default: 500.
  retry_backoff_ms : Int
} derive(Eq, Debug)

///|
/// Default config builder. api_key is required; other fields use defaults.
pub fn DeepSeekConfig::new(
  api_key : String,
  base_url? : String = "https://api.deepseek.com",
  chat_model? : String = "deepseek-chat",
  reasoner_model? : String = "deepseek-reasoner",
  coder_model? : String = "deepseek-coder",
  thinking? : ThinkingMode = No,
  retry_attempts? : Int = 3,
  retry_backoff_ms? : Int = 500,
) -> DeepSeekConfig {
  {
    api_key,
    base_url,
    chat_model,
    reasoner_model,
    coder_model,
    thinking,
    retry_attempts,
    retry_backoff_ms,
  }
}

///|
/// The DeepSeek ModelPort implementation. Implements @posoco.ModelPort for
/// chat/chat_streaming (standard trait path) and exposes DeepSeek-native APIs
/// (fim_completion, chat_prefix_completion) as extension methods.
pub(all) struct DeepSeekModelPort {
  config : DeepSeekConfig
}

///|
pub fn DeepSeekModelPort::new(config : DeepSeekConfig) -> DeepSeekModelPort {
  { config, }
}

///|
/// Map posoco's ReasoningEffort to a DeepSeek model name + thinking mode.
/// DeepSeek reasoning is binary: Off → deepseek-chat (no reasoning);
/// anything else → deepseek-reasoner. The effort tier collapses (DeepSeek
/// currently has no per-tier reasoning budget beyond model selection).
fn resolve_model(
  config : DeepSeekConfig,
  options : @posoco.ChatOptions,
) -> (String, ThinkingMode) {
  match options.reasoning_effort {
    None => (config.chat_model, config.thinking)
    Some(Off) => (config.chat_model, No)
    Some(_) => (config.reasoner_model, config.thinking)
  }
}
