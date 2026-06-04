///|
/// posoco_helpers.mbt — Convenience functions for posoco agent development.
///
/// Provides concise constructors for Message, AgentConfig defaults,
/// and other commonly repeated patterns.

///|
/// Construct a User-role text Message.
pub fn user_message(text : String) -> @posoco.Message {
  {
    role: @posoco.Role::User,
    content: [@posoco.Content::Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
}

///|
/// Construct an Assistant-role text Message.
pub fn assistant_message(text : String) -> @posoco.Message {
  {
    role: @posoco.Role::Assistant,
    content: [@posoco.Content::Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
}

///|
/// Construct a System-role text Message.
pub fn system_message(text : String) -> @posoco.Message {
  {
    role: @posoco.Role::System,
    content: [@posoco.Content::Text(text)],
    tool_calls: [],
    tool_call_id: None,
    name: None,
  }
}

///|
/// Construct a Tool-role Message from a tool call result.
pub fn tool_message(
  call_id : String,
  name : String,
  content : String,
) -> @posoco.Message {
  {
    role: @posoco.Role::Tool,
    content: [@posoco.Content::Text(content)],
    tool_calls: [],
    tool_call_id: Some(call_id),
    name: Some(name),
  }
}

///|
/// Default AgentConfig with sensible values.
/// max_tool_rounds=10, all other options None.
pub fn default_agent_config() -> @posoco.AgentConfig {
  {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    thinking: None,
    model_context_window: None,
  }
}
