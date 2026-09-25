///|
/// Interactive ask_question tool backed by Posoco's composed UiPort. The
/// port is captured from the CompositionView at composition time (manifest
/// declares `requires: [Capability::Ui]`), so requests ride the aggregated
/// port — never a host-provided raw contributor reference.
pub(all) struct AskQuestionTools {
  mut ui : &@posoco.UiPort?
}

///|
/// Construct an ask-question extension. The composed UI is wired during
/// composition; constructing without a host that contributes a UiPort makes
/// every ask_question report "ui unavailable".
pub fn AskQuestionTools::AskQuestionTools() -> AskQuestionTools {
  { ui: None, }
}

///|
fn ask_question_schema() -> Json {
  Json::object({
    "type": Json::string("object"),
    "properties": Json::object({
      "question": Json::object({
        "type": Json::string("string"),
        "description": Json::string(
          "One focused question to present to the user",
        ),
      }),
      "type": Json::object({
        "type": Json::string("string"),
        "enum": Json::array([
          Json::string("input"),
          Json::string("confirm"),
          Json::string("select"),
        ]),
      }),
      "options": Json::object({
        "type": Json::string("array"),
        "items": Json::object({ "type": Json::string("string") }),
        "description": Json::string("Concise choices for a select prompt"),
      }),
      "default": Json::object({
        "type": Json::string("string"),
        "description": Json::string("Pre-filled input value"),
      }),
      "default_index": Json::object({
        "type": Json::string("integer"),
        "description": Json::string("Zero-based default choice"),
      }),
    }),
    "required": Json::array([Json::string("question")]),
  })
}

///|
fn string_field(
  fields : Map[String, Json],
  key : String,
) -> String? raise @posoco.RuntimeError {
  match fields.get(key) {
    None => None
    Some(Json::String(value)) => Some(value)
    Some(_) =>
      raise @posoco.RuntimeError::UnknownTool(
        "ask_question: '" + key + "' must be a string",
      )
  }
}

///|
fn options_field(
  fields : Map[String, Json],
) -> Array[String] raise @posoco.RuntimeError {
  match fields.get("options") {
    None => []
    Some(Json::Array(values)) => {
      let options : Array[String] = []
      for value in values {
        match value {
          Json::String(option) => options.push(option)
          _ =>
            raise @posoco.RuntimeError::UnknownTool(
              "ask_question: option must be a string",
            )
        }
      }
      options
    }
    Some(_) =>
      raise @posoco.RuntimeError::UnknownTool(
        "ask_question: 'options' must be string[]",
      )
  }
}

///|
fn default_index_field(
  fields : Map[String, Json],
) -> Int? raise @posoco.RuntimeError {
  match fields.get("default_index") {
    None => None
    Some(Json::Number(value, ..)) => Some(value.to_int())
    Some(_) =>
      raise @posoco.RuntimeError::UnknownTool(
        "ask_question: 'default_index' must be an integer",
      )
  }
}

///|
priv struct AskSpec {
  question : String
  prompt_type : String
  options : Array[String]
  default_text : String?
  default_index : Int?
}

///|
fn parse_ask_spec(arguments : Json) -> AskSpec raise @posoco.RuntimeError {
  let fields = match arguments {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "ask_question: arguments must be an object",
      )
  }
  let question = match string_field(fields, "question") {
    Some(value) if value.trim() != "" => value
    Some(_) =>
      raise @posoco.RuntimeError::UnknownTool("ask_question: empty 'question'")
    None =>
      raise @posoco.RuntimeError::UnknownTool(
        "ask_question: missing 'question'",
      )
  }
  let options = options_field(fields)
  let requested_type = string_field(fields, "type")
  let prompt_type = match requested_type {
    Some(value) => value
    None => if options.is_empty() { "input" } else { "select" }
  }
  if prompt_type != "input" &&
    prompt_type != "confirm" &&
    prompt_type != "select" {
    raise @posoco.RuntimeError::UnknownTool("ask_question: invalid 'type'")
  }
  let default_index = default_index_field(fields)
  if prompt_type == "select" {
    if options.is_empty() {
      raise @posoco.RuntimeError::UnknownTool(
        "ask_question: select requires options",
      )
    }
    match default_index {
      Some(index) if index < 0 || index >= options.length() =>
        raise @posoco.RuntimeError::UnknownTool(
          "ask_question: default_index out of bounds",
        )
      _ => ()
    }
  }
  {
    question,
    prompt_type,
    options,
    default_text: string_field(fields, "default"),
    default_index,
  }
}

///|
fn AskSpec::request(self : AskSpec) -> @posoco.UiRequest {
  match self.prompt_type {
    "confirm" => @posoco.UiRequest::Confirm(prompt=self.question)
    "select" =>
      @posoco.UiRequest::Select(
        prompt=self.question,
        options=self.options,
        default=self.default_index,
      )
    _ =>
      @posoco.UiRequest::Input(prompt=self.question, default=self.default_text)
  }
}

///|
fn success_text(text : String, kind : String) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::Success(
    content=text,
    structured=Some(
      Json::object({ "type": Json::string(kind), "value": Json::string(text) }),
    ),
  )
}

///|
fn response_outcome(
  spec : AskSpec,
  response : @posoco.UiResponse,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  match response {
    @posoco.UiResponse::Text(text) => success_text(text, "input")
    @posoco.UiResponse::Yes =>
      @posoco.ToolOutcome::Success(
        content="yes",
        structured=Some(
          Json::object({
            "type": Json::string("confirm"),
            "value": Json::boolean(true),
          }),
        ),
      )
    @posoco.UiResponse::No =>
      @posoco.ToolOutcome::Success(
        content="no",
        structured=Some(
          Json::object({
            "type": Json::string("confirm"),
            "value": Json::boolean(false),
          }),
        ),
      )
    @posoco.UiResponse::Selected(index) => {
      if index < 0 || index >= spec.options.length() {
        raise @posoco.RuntimeError::InvocationFailed(
          "ask_question: UI selection out of bounds",
        )
      }
      let value = spec.options[index]
      @posoco.ToolOutcome::Success(
        content=value,
        structured=Some(
          Json::object({
            "type": Json::string("select"),
            "index": Json::number(index.to_double()),
            "value": Json::string(value),
          }),
        ),
      )
    }
    @posoco.UiResponse::Cancelled =>
      @posoco.ToolOutcome::ToolReportedError(
        content="cancelled",
        structured=Some(Json::object({ "cancelled": Json::boolean(true) })),
      )
  }
}

///|
pub impl @posoco.ToolProvider for AskQuestionTools with fn list_tools(
  _self : AskQuestionTools,
) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: @posoco.ToolName::unchecked("ask_question"),
      description: "Ask exactly one focused user question only when a user decision or missing fact blocks progress. Do not ask for information available tools can discover. If known choices exist, prefer type=select with concise options; use type=confirm for yes/no; otherwise use type=input.",
      input_schema: ask_question_schema(),
      owner: @posoco.OwnerId::unchecked("posoco_ext_askquestion"),
      policy: @posoco.ExecutionPolicy::Exclusive,
      provenance: Some("posoco_ext_askquestion"),
    },
  ]
}

///|
pub impl @posoco.ToolProvider for AskQuestionTools with fn execute(
  self : AskQuestionTools,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name != "ask_question" {
    raise @posoco.RuntimeError::UnknownTool(
      "posoco_ext_askquestion: unknown tool '" + name + "'",
    )
  }
  let spec = parse_ask_spec(call.arguments)
  let ui = match self.ui {
    Some(ui) => ui
    None =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="ui unavailable",
        structured=None,
      )
  }
  let response = ui.request(spec.request()) catch {
    @posoco.UiError::Unsupported(detail~) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="ui unavailable: " + detail,
        structured=None,
      )
    @posoco.UiError::Cancelled =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="cancelled",
        structured=Some(Json::object({ "cancelled": Json::boolean(true) })),
      )
    @posoco.UiError::InvalidRequest(detail~) =>
      raise @posoco.RuntimeError::InvocationFailed(
        "ask_question: invalid UI: " + detail,
      )
    @posoco.UiError::IoFailure(detail~) =>
      raise @posoco.RuntimeError::InvocationFailed(
        "ask_question: UI: " + detail,
      )
  }
  response_outcome(spec, response)
}

///|
pub impl @posoco.SystemPromptContributor for AskQuestionTools with fn system_prompt(
  _self : AskQuestionTools,
) -> String {
  "Use ask_question only when a user decision or missing fact blocks progress. Ask one focused question at a time. Prefer select with concise known choices; otherwise use input. Do not ask for information available tools can discover."
}

///|
pub impl @posoco.Extension for AskQuestionTools with fn extension_id(
  _self : AskQuestionTools,
) -> String {
  "posoco_ext_askquestion"
}

///|
pub impl @posoco.Extension for AskQuestionTools with fn manifest(
  self : AskQuestionTools,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_askquestion",
    requires=[@posoco.Capability::Ui],
    lifecycle=[self],
    tools=[self],
  )
}

///|
pub impl @posoco.Lifecycle for AskQuestionTools with fn on_compose(
  self : AskQuestionTools,
  view : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.ui = view.ui()
}

///|
pub extend AskQuestionTools with @posoco.Lifecycle::{
  on_compose,
  on_shutdown,
  on_start,
}

///|
pub impl @posoco.Lifecycle for AskQuestionTools with fn on_shutdown(
  _self : AskQuestionTools,
) -> Unit {
  ()
}

///|
pub extend AskQuestionTools with @posoco.ToolProvider::{list_tools, execute}

///|
pub extend AskQuestionTools with @posoco.SystemPromptContributor::{
  system_prompt,
}

///|
pub extend AskQuestionTools with @posoco.Extension::{extension_id, manifest}
