///|
/// Default OpenAI-compatible behavior. No vendor-only keys, no replay policy.
pub fn standard() -> ChatCompatibility {
  {
    id: "standard",
    accepts: fn(_model) { false },
    apply_params: fn(body, thinking, effort) {
      if thinking {
        match effort {
          Some(value) if value != "none" =>
            body["reasoning_effort"] = Json::string(value)
          _ => ()
        }
      }
    },
    check_history: fn(_messages, _tools, _thinking, _effort) { () },
    check_completion: fn(_completion, _tools, _thinking, _effort) { () },
    explicit_terminal: fn(_thinking, _effort) { false },
  }
}
