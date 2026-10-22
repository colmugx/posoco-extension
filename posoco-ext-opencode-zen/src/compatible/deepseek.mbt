///|
/// DeepSeek Chat Completions compatibility contract (ONLY for explicitly
/// selected deepseek* Chat Completions models in Go/Zen). Never applied to
/// GLM, Kimi, Messages, Responses, or the standard OpenAI-compatible kit.
///
/// No replay gates. The hybrid thinking models on this route legitimately
/// skip thinking on a large share of tool-call turns (60/102 streams in the
/// 2026-10-22 business-run wire capture), and the upstream accepts
/// reasoning-less assistant turns replayed back — all 60 skip-replay cycles
/// completed without a 400. An earlier pair of gates rejected turns whose
/// completion or history lacked reasoning_content, on the static assumption
/// that a missing reasoning replay 400s; that premise holds only for turns
/// where reasoning was produced and lost (the alias-normalization fix in
/// `sse.mbt` addresses that root cause), not for turns where the model
/// never thought. Enforcing the stricter invariant turned legitimate
/// upstream behavior into unrecoverable local failures.
fn ds_thinking_enabled(thinking : Bool, effort : String?) -> Bool {
  thinking && effort != Some("none")
}

///|
pub fn deepseek() -> ChatCompatibility {
  {
    id: "deepseek",
    accepts: fn(model) { model.has_prefix("deepseek") },
    apply_params: fn(body, thinking, effort) {
      let enabled = ds_thinking_enabled(thinking, effort)
      // A missing thinking field defaults to enabled on DeepSeek.
      body["thinking"] = Json::object({
        "type": Json::string(if enabled { "enabled" } else { "disabled" }),
      })
      if enabled {
        match effort {
          Some(value) => body["reasoning_effort"] = Json::string(value)
          None => ()
        }
      }
    },
    check_history: fn(_messages, _tools, _thinking, _effort) { () },
    check_completion: fn(_completion, _tools, _thinking, _effort) { () },
    explicit_terminal: ds_thinking_enabled,
  }
}
