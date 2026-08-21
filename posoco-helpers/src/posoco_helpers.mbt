///|
/// posoco_helpers.mbt — Convenience functions for posoco agent development.
///
/// Provides concise constructors for Message, AgentConfig defaults,
/// and other commonly repeated patterns.

///|
/// Construct a User-role text Message.
pub fn user_message(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
/// Construct an Assistant-role text Message.
pub fn assistant_message(text : String) -> @posoco.Message {
  @posoco.Message::AssistantMessage(
    content=[@posoco.Content::Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
/// Construct a System-role text Message.
pub fn system_message(text : String) -> @posoco.Message {
  @posoco.Message::SystemMessage(content=[@posoco.Content::Text(text)])
}

///|
/// Construct a Tool-role Message from a tool call result.
pub fn tool_message(
  call_id : String,
  name : String,
  content : String,
) -> @posoco.Message {
  @posoco.Message::ToolMessage(
    call_id=@posoco.CallId::unchecked(call_id),
    tool_name=@posoco.ToolName::unchecked(name),
    outcome=@posoco.ToolOutcome::Success(content~, structured=None),
  )
}

///|
/// Default AgentConfig with sensible values.
/// max_tool_rounds=Some(10), all other universal options None.
pub fn default_agent_config() -> @posoco.AgentConfig {
  {
    max_tool_rounds: Some(10),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
  }
}
