///|
/// Extensible per-model Chat Completions compatibility hooks. Standard
/// OpenAI-compatible parsing/encoding does not know vendor-specific rules.
/// Adding a dialect means adding one implementation and registering it here,
/// never extending an if/else chain in the transport.
pub(all) struct ChatCompatibility {
  id : String
  accepts : (String) -> Bool
  apply_params : (Map[String, Json], Bool, String?) -> Unit
  check_history : (Array[@posoco.Message], Bool, Bool, String?) -> Unit raise @posoco.ModelError
  check_completion : (@posoco.Completion, Bool, Bool, String?) -> Unit raise @posoco.ModelError
  explicit_terminal : (Bool, String?) -> Bool
}

///|
pub fn ChatCompatibility::apply_request(
  self : ChatCompatibility,
  body : Map[String, Json],
  thinking : Bool,
  effort : String?,
) -> Unit {
  (self.apply_params)(body, thinking, effort)
}

///|
pub fn ChatCompatibility::validate_history(
  self : ChatCompatibility,
  messages : Array[@posoco.Message],
  tools_present : Bool,
  thinking : Bool,
  effort : String?,
) -> Unit raise @posoco.ModelError {
  (self.check_history)(messages, tools_present, thinking, effort)
}

///|
pub fn ChatCompatibility::validate_completion(
  self : ChatCompatibility,
  completion : @posoco.Completion,
  tools_present : Bool,
  thinking : Bool,
  effort : String?,
) -> Unit raise @posoco.ModelError {
  (self.check_completion)(completion, tools_present, thinking, effort)
}

///|
pub fn ChatCompatibility::requires_terminal(
  self : ChatCompatibility,
  thinking : Bool,
  effort : String?,
) -> Bool {
  (self.explicit_terminal)(thinking, effort)
}

///|
/// This registry is the sole place new dialects are registered. The caller
/// resolves it only after selecting the Chat Completions wire; other wires
/// never pass through this compatibility layer.
pub fn resolve(model : String) -> ChatCompatibility {
  for profile in [deepseek(), glm()] {
    if (profile.accepts)(model) {
      return profile
    }
  }
  standard()
}
