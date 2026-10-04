///|
/// Qwen model metadata that changes the Chat Completions wire contract.
priv struct QwenModelInfo {
  efforts : Array[String]
  default_effort : String
  preserve_thinking_default : Bool
  tool_stream_default : Bool
  vision : Bool
}

///|
fn qwen_model_info(model : String) -> QwenModelInfo? {
  if model.has_prefix("qwen3.8-max") {
    Some({
      efforts: ["low", "medium", "xhigh"],
      default_effort: "xhigh",
      preserve_thinking_default: true,
      tool_stream_default: true,
      vision: true,
    })
  } else if model.has_prefix("qwen3.8-flash") {
    Some({
      efforts: ["low", "medium", "xhigh"],
      default_effort: "xhigh",
      preserve_thinking_default: true,
      tool_stream_default: true,
      vision: true,
    })
  } else if model.has_prefix("qwen3.8-omni-flash") {
    Some({
      efforts: ["low", "medium", "xhigh"],
      default_effort: "xhigh",
      preserve_thinking_default: true,
      tool_stream_default: false,
      vision: true,
    })
  } else {
    None
  }
}

///|
fn qwen_reasoning_effort_supported(value : String) -> Bool {
  ["none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(value)
}

///|
pub(all) struct QwenConfig {
  api_key : String
  base_url : String
  endpoint_prefix : String
  model : String
  reasoning_effort : String?
  enable_thinking : Bool?
  preserve_thinking : Bool
  emit_preserve_thinking : Bool
  tool_stream : Bool
  supports_images : Bool
  context_window : Int?
} derive(Eq, Debug)

///|
pub extend QwenConfig with Eq::{not_equal, equal}

///|
pub extend QwenConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn QwenConfig::QwenConfig(
  api_key : String,
  base_url~ : String,
  model? : String = "qwen3.8-max",
  endpoint_prefix? : String = "",
  reasoning_effort? : String? = None,
  enable_thinking? : Bool? = None,
  preserve_thinking? : Bool? = None,
  tool_stream? : Bool? = None,
  supports_images? : Bool? = None,
  context_window? : Int? = None,
) -> QwenConfig {
  if reasoning_effort is Some(_) && enable_thinking is Some(_) {
    abort(
      "posoco-ext-qwen: reasoning_effort and enable_thinking are mutually exclusive",
    )
  }
  match reasoning_effort {
    Some(value) =>
      if !qwen_reasoning_effort_supported(value) {
        abort("posoco-ext-qwen: unsupported reasoning effort: " + value)
      }
    None => ()
  }
  match context_window {
    Some(window) =>
      if window <= 0 {
        abort("posoco-ext-qwen: context_window must be positive")
      }
    None => ()
  }
  let info = qwen_model_info(model)
  let effective_effort : String? = match reasoning_effort {
    Some(value) => Some(value)
    None =>
      if enable_thinking is Some(_) {
        None
      } else {
        match info {
          Some(value) => Some(value.default_effort)
          None => None
        }
      }
  }
  let effective_preserve = match preserve_thinking {
    Some(value) => value
    None =>
      match info {
        Some(value) => value.preserve_thinking_default
        None => false
      }
  }
  let emit_preserve = preserve_thinking is Some(_) || info is Some(_)
  let effective_tool_stream = match tool_stream {
    Some(value) => value
    None =>
      match info {
        Some(value) => value.tool_stream_default
        None => false
      }
  }
  let effective_images = match supports_images {
    Some(value) => value
    None =>
      match info {
        Some(value) => value.vision
        None => false
      }
  }
  {
    api_key,
    base_url,
    endpoint_prefix,
    model,
    reasoning_effort: effective_effort,
    enable_thinking,
    preserve_thinking: effective_preserve,
    emit_preserve_thinking: emit_preserve,
    tool_stream: effective_tool_stream,
    supports_images: effective_images,
    context_window,
  }
}

///|
fn qwen_slot_efforts(config : QwenConfig) -> Array[String] {
  match qwen_model_info(config.model) {
    Some(info) => {
      let values : Array[String] = ["off"]
      values.append(info.efforts.copy())
      values
    }
    None => if config.enable_thinking is Some(_) { ["off", "on"] } else { [] }
  }
}

///|
fn qwen_effort_label(config : QwenConfig) -> String {
  match qwen_model_info(config.model) {
    Some(_) =>
      match config.reasoning_effort {
        Some("none") | None => "off"
        Some(value) => value
      }
    None =>
      match config.enable_thinking {
        Some(true) => "on"
        Some(false) | None => "off"
      }
  }
}

///|
pub fn QwenConfig::with_reasoning_effort(
  self : QwenConfig,
  effort : String,
) -> QwenConfig raise @posoco.CompositionError {
  match qwen_model_info(self.model) {
    Some(info) => {
      if effort == "off" {
        return {
          ..self,
          reasoning_effort: Some("none"),
          enable_thinking: None,
        }
      }
      if !info.efforts.contains(effort) {
        raise @posoco.CompositionError::ManifestSchemaError(
          manifest_id="posoco_ext_qwen",
          detail="unsupported reasoning effort: " + effort,
        )
      }
      { ..self, reasoning_effort: Some(effort), enable_thinking: None, }
    }
    None =>
      match effort {
        "off" =>
          { ..self, reasoning_effort: None, enable_thinking: Some(false), }
        "on" => { ..self, reasoning_effort: None, enable_thinking: Some(true), }
        _ =>
          raise @posoco.CompositionError::ManifestSchemaError(
            manifest_id="posoco_ext_qwen",
            detail="unsupported reasoning effort: " + effort,
          )
      }
  }
}

///|
pub(all) struct QwenModelPort {
  config : QwenConfig
  ctx : @devkit.ExtContext
}

///|
pub fn QwenModelPort::QwenModelPort(
  config : QwenConfig,
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> QwenModelPort {
  { config, ctx, }
}
