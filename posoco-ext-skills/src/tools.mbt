///|
fn skill_name_enum(catalog : SkillCatalog) -> Json {
  let values : Array[Json] = []
  for skill in catalog.skills {
    values.push(Json::string(skill.name))
  }
  Json::array(values)
}

///|
fn Skills::activate_tool_def(self : Skills) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(self.config.activate_tool_name),
    description: "Activate one discovered Agent Skill. Returns the full SKILL.md instructions on demand and lists bundled resources without loading them. Use the exact skill name from the available-skills catalog.",
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "name": Json::object({
          "type": Json::string("string"),
          "description": Json::string("Exact discovered skill name"),
          "enum": skill_name_enum(self.catalog),
        }),
      }),
      "required": Json::array([Json::string("name")]),
      "additionalProperties": Json::boolean(false),
    }),
    owner: @posoco.OwnerId::unchecked("posoco_ext_skills"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_skills"),
  }
}

///|
fn Skills::read_resource_tool_def(self : Skills) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(self.config.read_resource_tool_name),
    description: "Read one UTF-8 text resource belonging to a discovered Agent Skill. Use this after that skill's activated instructions identify a resource that is actually needed. The path is resolved inside the discovered skill directory and cannot escape it.",
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "name": Json::object({
          "type": Json::string("string"),
          "description": Json::string("Exact discovered skill name"),
          "enum": skill_name_enum(self.catalog),
        }),
        "path": Json::object({
          "type": Json::string("string"),
          "description": Json::string(
            "Resource path relative to the skill directory",
          ),
        }),
      }),
      "required": Json::array([Json::string("name"), Json::string("path")]),
      "additionalProperties": Json::boolean(false),
    }),
    owner: @posoco.OwnerId::unchecked("posoco_ext_skills"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_skills"),
  }
}

///|
pub impl @posoco.ToolProvider for Skills with fn list_tools(self) -> Array[
  @posoco.ToolDef,
] {
  if self.catalog.skills.is_empty() {
    []
  } else {
    [self.activate_tool_def(), self.read_resource_tool_def()]
  }
}

///|
fn require_string_arg(
  tool : String,
  args : Json,
  key : String,
) -> String raise @posoco.RuntimeError {
  match args {
    Object(obj) =>
      match obj.get(key) {
        Some(String(value)) => value
        Some(_) =>
          raise @posoco.RuntimeError::InvocationFailed(
            tool + ": '" + key + "' argument must be a string",
          )
        None =>
          raise @posoco.RuntimeError::InvocationFailed(
            tool + ": missing '" + key + "' argument",
          )
      }
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        tool + ": arguments must be a JSON object",
      )
  }
}

///|
pub impl @posoco.ToolProvider for Skills with fn execute(
  self : Skills,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name == self.config.activate_tool_name {
    let skill_name = require_string_arg(name, call.arguments, "name")
    if !runtime_skill_name_is_safe(skill_name) {
      raise @posoco.RuntimeError::InvocationFailed(
        name + ": 'name' exceeds runtime safety constraints",
      )
    }
    return self.activate(skill_name)
  }
  if name == self.config.read_resource_tool_name {
    let skill_name = require_string_arg(name, call.arguments, "name")
    if !runtime_skill_name_is_safe(skill_name) {
      raise @posoco.RuntimeError::InvocationFailed(
        name + ": 'name' exceeds runtime safety constraints",
      )
    }
    let path = require_string_arg(name, call.arguments, "path")
    return self.read_resource(skill_name, path)
  }
  raise @posoco.RuntimeError::UnknownTool("posoco_ext_skills: unknown tool")
}
