///|
const SKILL_SEARCH_TOOL_NAME = "skill_search"

///|
/// Bound model-visible skill descriptions; internal matching keeps the full
/// descriptor text.
const SKILL_DESCRIPTION_PREVIEW_CHARS = 1024

///|
fn Skills::search_tool_def(self : Skills) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(SKILL_SEARCH_TOOL_NAME),
    description: "Find relevant skills by task or capability. Returns names plus short descriptions; activate an exact returned name with " +
    self.config.activate_tool_name +
    ".",
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "query": Json::object({
          "type": Json::string("string"),
          "description": Json::string("Task or capability"),
        }),
      }),
      "required": Json::array([Json::string("query")]),
      "additionalProperties": Json::boolean(false),
    }),
    owner: @posoco.OwnerId::unchecked("posoco_ext_skills"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_skills"),
  }
}

///|
fn skill_search_json(skill : SkillDescriptor) -> Json {
  Json::object({
    "name": Json::string(skill.name),
    "description": Json::string(skill.description),
  })
}

///|
fn skill_search_success(
  skills : Array[SkillDescriptor],
  query : String,
  indexed : Int32,
) -> @posoco.ToolOutcome {
  let values : Array[Json] = []
  let lines : Array[String] = []
  for skill in skills {
    values.push(skill_search_json(skill))
    lines.push(
      "\{skill.name}: \{unicode_scalar_preview(skill.description, SKILL_DESCRIPTION_PREVIEW_CHARS)}",
    )
  }
  // Distinguish "nothing matched this query" from "no skills exist": the tool
  // is only registered for a non-empty catalog, so the model should retry with
  // different keywords rather than conclude the catalog is empty.
  let content = if skills.is_empty() {
    "(no match among \{indexed} skills)"
  } else {
    lines.join("\n")
  }
  @posoco.ToolOutcome::Success(
    content~,
    structured=Some(
      Json::object({
        "query": Json::string(query),
        "skills": Json::array(values),
      }),
    ),
  )
}

///|
fn Skills::search(self : Skills, query : String) -> @posoco.ToolOutcome {
  let indexed = self.catalog.skills.length()
  let tokens = query_tokens(query)
  if tokens.is_empty() {
    return skill_search_success([], query, indexed)
  }
  skill_search_success(self.rank_skills(tokens), query, indexed)
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
          "description": Json::string("Exact skill name"),
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
    [
      self.activate_tool_def(),
      self.read_resource_tool_def(),
      self.search_tool_def(),
    ]
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
            tool + ": '" + key + "' must be a string",
          )
        None =>
          raise @posoco.RuntimeError::InvocationFailed(
            tool + ": missing '" + key + "'",
          )
      }
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        tool + ": arguments must be an object",
      )
  }
}

///|
pub impl @posoco.ToolProvider for Skills with fn execute(
  self : Skills,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  if name == SKILL_SEARCH_TOOL_NAME {
    let query = require_string_arg(name, ctx.arguments, "query")
    if query.trim().is_empty() || query.length() > 4096 {
      raise @posoco.RuntimeError::InvocationFailed(
        name + ": 'query' must be 1..4096 chars",
      )
    }
    return self.search(query)
  }
  if name == self.config.activate_tool_name {
    let skill_name = require_string_arg(name, ctx.arguments, "name")
    if !runtime_skill_name_is_safe(skill_name) {
      raise @posoco.RuntimeError::InvocationFailed(
        name + ": 'name' exceeds runtime safety constraints",
      )
    }
    return self.activate(skill_name)
  }
  if name == self.config.read_resource_tool_name {
    let skill_name = require_string_arg(name, ctx.arguments, "name")
    if !runtime_skill_name_is_safe(skill_name) {
      raise @posoco.RuntimeError::InvocationFailed(
        name + ": 'name' exceeds runtime safety constraints",
      )
    }
    let path = require_string_arg(name, ctx.arguments, "path")
    return self.read_resource(skill_name, path)
  }
  raise @posoco.RuntimeError::UnknownTool("posoco_ext_skills: unknown tool")
}
