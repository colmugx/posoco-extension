///|
/// Shared message builders for the compact-summary whitebox tests.

///|
fn user_msg(text : String) -> @posoco.Message {
  UserMessage(content=[Text(text)])
}

///|
fn system_msg(text : String) -> @posoco.Message {
  SystemMessage(content=[Text(text)])
}

///|
fn asst_msg(text : String, calls : Array[@posoco.ToolCall]) -> @posoco.Message {
  AssistantMessage(
    content=[Text(text)],
    tool_calls=calls,
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
  )
}

///|
fn tool_call(name : String, args : Json) -> @posoco.ToolCall {
  @posoco.ToolCall::{
    call_id: @posoco.CallId::unchecked("call_" + name),
    name: @posoco.ToolName::unchecked(name),
    arguments: args,
  }
}

///|
fn tool_result(name : String, content : String) -> @posoco.Message {
  ToolMessage(
    call_id=@posoco.CallId::unchecked("call_" + name),
    tool_name=@posoco.ToolName::unchecked(name),
    outcome=Success(content~, structured=None),
  )
}

///|
fn tool_error(name : String, content : String) -> @posoco.Message {
  ToolMessage(
    call_id=@posoco.CallId::unchecked("call_" + name),
    tool_name=@posoco.ToolName::unchecked(name),
    outcome=ToolReportedError(content~, structured=None),
  )
}

///|
fn tool_runtime_failure(name : String, message : String) -> @posoco.Message {
  ToolMessage(
    call_id=@posoco.CallId::unchecked("call_" + name),
    tool_name=@posoco.ToolName::unchecked(name),
    outcome=RuntimeFailure(error_category="io", message~),
  )
}

///|
fn tool_not_executed(name : String) -> @posoco.Message {
  ToolMessage(
    call_id=@posoco.CallId::unchecked("call_" + name),
    tool_name=@posoco.ToolName::unchecked(name),
    outcome=NotExecuted(
      reason=@posoco.NotExecutedReason::UnknownTool,
      original_call_id=@posoco.CallId::unchecked("call_" + name),
    ),
  )
}

///|
fn args_json(pairs : Array[(String, String)]) -> Json {
  let fields : Array[(String, Json)] = []
  for pair in pairs {
    let (key, value) = pair
    fields.push((key, Json::string(value)))
  }
  Json::object(Map::from_array(fields))
}

///|
fn parse_json(text : String) -> Json {
  try! @json.parse(text)
}

///|
fn text_of(message : @posoco.Message) -> String {
  match message {
    UserMessage(content~) => first_text(content)
    SystemMessage(content~) => first_text(content)
    AssistantMessage(content~, ..) => first_text(content)
    ToolMessage(..) => ""
  }
}

///|
fn first_text(content : Array[@posoco.Content]) -> String {
  for block in content {
    match block {
      Text(text) => return text
      Image(..) => ()
    }
  }
  ""
}
