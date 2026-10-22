///|
/// DeepSeek Chat Completions compatibility contract (ONLY for explicitly
/// selected deepseek* Chat Completions models in Go/Zen). Never applied to
/// GLM, Kimi, Messages, Responses, or the standard OpenAI-compatible kit.
///
/// Missing historical reasoning cannot be reconstructed by inventing empty
/// or whitespace reasoning_content: fail locally with the message index.
fn ds_thinking_enabled(thinking : Bool, effort : String?) -> Bool {
  thinking && effort != Some("none")
}

///|
fn ds_check_history(
  messages : Array[@posoco.Message],
  tools_present : Bool,
  thinking : Bool,
  effort : String?,
) -> Unit raise @posoco.ModelError {
  if !ds_thinking_enabled(thinking, effort) || !tools_present {
    return
  }
  for i in 0..<messages.length() {
    match messages[i] {
      @posoco.Message::AssistantMessage(reasoning~, ..) =>
        match reasoning {
          Some(r) if r.content.length() > 0 => ()
          _ => raise @posoco.ModelError::ResponseParse(
            "DeepSeek replay blocked: assistant history lacks reasoning_content (index=\{i}); use a clean conversation or safe compaction",
          )
        }
      _ => ()
    }
  }
}

///|
fn ds_check_completion(
  completion : @posoco.Completion,
  tools_present : Bool,
  thinking : Bool,
  effort : String?,
) -> Unit raise @posoco.ModelError {
  if ds_thinking_enabled(thinking, effort) &&
    (tools_present || completion.has_tool_calls()) {
    match completion.message.reasoning {
      Some(r) if r.content.length() > 0 => ()
      _ => raise @posoco.ModelError::ResponseParse(
        "DeepSeek replay integrity failure: completion lacks reasoning_content",
      )
    }
  }
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
    check_history: ds_check_history,
    check_completion: ds_check_completion,
    explicit_terminal: ds_thinking_enabled,
  }
}
