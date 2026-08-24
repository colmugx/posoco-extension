///|
/// z.ai/bigmodel GLM endpoint presets. The Coding Plan only honors plan
/// quota on the coding endpoints; the general endpoints bill balance.
pub fn zai_profile_endpoint(profile : String) -> (String, String)? {
  match profile {
    "coding" => Some(("https://api.z.ai", "/api/coding/paas/v4"))
    "general" => Some(("https://api.z.ai", "/api/paas/v4"))
    "cn" => Some(("https://open.bigmodel.cn", "/api/paas/v4"))
    "cn_coding" => Some(("https://open.bigmodel.cn", "/api/coding/paas/v4"))
    _ => None
  }
}

///|
/// GLM models the plan serves, with their picker-facing reasoning efforts.
/// GLM-4.x takes `thinking: {type}` but no `reasoning_effort` (that field is
/// GLM-5.2+); those models are always-on thinkers with no selector.
struct ZaiModelInfo {
  id : String
  efforts : Array[String]
  default_effort : String
  thinking_always : Bool
}

///|
fn zai_models() -> Array[ZaiModelInfo] {
  [
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
      id: "glm-5.1",
      efforts: ["low", "high", "max"],
      default_effort: "high",
      thinking_always: false,
    },
    {
      id: "glm-5",
      efforts: ["low", "high", "max"],
      default_effort: "high",
      thinking_always: false,
    },
    {
      id: "glm-5-turbo",
      efforts: ["low", "high", "max"],
      default_effort: "high",
      thinking_always: false,
    },
    { id: "glm-4.7", efforts: [], default_effort: "", thinking_always: true },
    { id: "glm-4.6", efforts: [], default_effort: "", thinking_always: true },
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
  None
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
  endpoint_prefix? : String = "/api/coding/paas/v4",
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
) -> ZaiConfig raise @posoco.CompositionError {
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
) -> ZaiConfig raise @posoco.CompositionError {
  if effort == "off" {
    return { ..self, reasoning_effort: "" }
  }
  if !self.thinking_efforts.contains(effort) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_zai",
      detail="unsupported reasoning effort: " + effort,
    )
  }
  { ..self, reasoning_effort: effort }
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
  { config, ctx }
}
