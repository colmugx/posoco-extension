///|
/// Z.ai / BigModel platform endpoint presets for direct API access
/// (pay-as-you-go balance). The GLM Coding Plan endpoints live in
/// posoco-ext-zai-coding-plan.
pub fn zai_platform_endpoint(platform : String) -> (String, String)? {
  match platform {
    "zai" => Some(("https://api.z.ai", "/api/paas/v4"))
    "bigmodel" => Some(("https://open.bigmodel.cn", "/api/paas/v4"))
    _ => None
  }
}

///|
/// GLM models the platform serves, with their picker-facing reasoning
/// efforts. GLM-4.x takes `thinking: {type}` but no `reasoning_effort` (that
/// field is GLM-5.2+); those models are always-on thinkers with no selector.
priv struct ZaiModelInfo {
  id : String
  efforts : Array[String]
  default_effort : String
  thinking_always : Bool
}

///|
fn zai_models() -> Array[ZaiModelInfo] {
  [
    {
      id: "glm-5.3-flash",
      efforts: ["low", "high", "max"],
      default_effort: "high",
      thinking_always: false,
    },
    {
      id: "glm-5.3",
      efforts: ["low", "high", "max"],
      default_effort: "high",
      thinking_always: false,
    },
    {
      id: "glm-5.2",
      efforts: ["low", "high", "max"],
      default_effort: "high",
      thinking_always: false,
    },
    {
      id: "glm-4.5-air",
      efforts: [],
      default_effort: "",
      thinking_always: true,
    },
  ]
}

///|
fn zai_model_info(model : String) -> ZaiModelInfo? {
  for info in zai_models() {
    if info.id == model {
      return Some(info)
    }
  }
  // Unknown ids (a release discovered through `/models` that the preset has
  // not caught up with) get their generation's thinking policy, so a live
  // model list yields correct pickers without a release lag.
  if model.has_prefix("glm-5") {
    Some(ZaiModelInfo::{
      id: model,
      efforts: ["low", "high", "max"],
      default_effort: "high",
      thinking_always: false,
    })
  } else if model.has_prefix("glm-4") {
    Some(ZaiModelInfo::{
      id: model,
      efforts: [],
      default_effort: "",
      thinking_always: true,
    })
  } else {
    None
  }
}

///|
/// `reasoning_effort == ""` disables thinking on the wire
/// (`thinking: {"type": "disabled"}`).
pub(all) struct ZaiConfig {
  api_key : String
  base_url : String
  model : String
  endpoint_prefix : String
  reasoning_effort : String
  thinking_efforts : Array[String]
} derive(Eq, Debug)

///|
pub fn ZaiConfig::ZaiConfig(
  api_key : String,
  model? : String = "glm-5.3",
  base_url? : String = "https://api.z.ai",
  endpoint_prefix? : String = "/api/paas/v4",
  reasoning_effort? : String = "",
  thinking_efforts? : Array[String] = ["low", "high", "max"],
) -> ZaiConfig {
  if !thinking_efforts.is_empty() &&
    reasoning_effort != "" &&
    !thinking_efforts.contains(reasoning_effort) {
    abort("posoco-ext-zai: unsupported reasoning effort: " + reasoning_effort)
  }
  {
    api_key,
    base_url,
    model,
    endpoint_prefix,
    reasoning_effort,
    thinking_efforts,
  }
}

///|
/// Config for a known model id with that model's default effort.
pub fn ZaiConfig::for_model(
  api_key : String,
  model : String,
  base_url~ : String,
  endpoint_prefix~ : String,
) -> ZaiConfig {
  match zai_model_info(model) {
    Some(info) => {
      let effort = if info.thinking_always || info.efforts.is_empty() {
        ""
      } else {
        info.default_effort
      }
      ZaiConfig(
        api_key,
        model~,
        base_url~,
        endpoint_prefix~,
        reasoning_effort=effort,
        thinking_efforts=info.efforts.copy(),
      )
    }
    None =>
      ZaiConfig(
        api_key,
        model~,
        base_url~,
        endpoint_prefix~,
        reasoning_effort="",
        thinking_efforts=[],
      )
  }
}

///|
/// Rebuild with a validated picker effort ("off" disables thinking).
pub fn ZaiConfig::with_reasoning_effort(
  self : ZaiConfig,
  effort : String,
  manifest_id? : String = "posoco_ext_zai",
) -> ZaiConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, reasoning_effort: "", }
  }
  if !self.thinking_efforts.contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id~,
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, reasoning_effort: effort, }
}

///|
pub(all) struct ZaiModelPort {
  config : ZaiConfig
  ctx : @devkit.ExtContext
}

///|
pub fn ZaiModelPort::ZaiModelPort(
  config : ZaiConfig,
  ctx? : @devkit.ExtContext = @devkit.ExtContext::default(),
) -> ZaiModelPort {
  { config, ctx, }
}
