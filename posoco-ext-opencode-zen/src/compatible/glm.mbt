///|
/// GLM gateway-specific thinking request shape. No DeepSeek replay checks.
pub fn glm() -> ChatCompatibility {
  {
    id: "glm",
    accepts: fn(model) { model.has_prefix("glm-") },
    apply_params: fn(body, thinking, effort) {
      if thinking {
        body["thinking"] = Json::object({
          "type": Json::string("enabled"),
        })
        match effort {
          Some(value) => body["reasoning_effort"] = Json::string(value)
          None => ()
        }
      }
    },
    check_history: fn(_messages, _tools, _thinking, _effort) { () },
    check_completion: fn(_completion, _tools, _thinking, _effort) { () },
    explicit_terminal: fn(_thinking, _effort) { false },
  }
}
