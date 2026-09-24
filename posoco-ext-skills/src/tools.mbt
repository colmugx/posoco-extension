///|
const SEMANTIC_SKILL_MIN_PROBABILITY = 0.6

///|
const SKILL_SEARCH_TOOL_NAME = "skill_search"

///|
/// Bound model-visible skill descriptions; internal matching keeps the full
/// descriptor text.
const SKILL_DESCRIPTION_PREVIEW_CHARS = 160

///|
fn Skills::search_tool_def(self : Skills) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(SKILL_SEARCH_TOOL_NAME),
    description: "Find relevant skills by task/capability. Returns names plus short descriptions; activate an exact returned name with " +
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
fn skill_search_tokens(query : String) -> Array[String] {
  query
  .to_lower()
  .split(" ")
  .filter(fn(view) { view != "" })
  .map(fn(view) { view.to_owned() })
  .to_array()
}

///|
fn skill_matches_query(skill : SkillDescriptor, tokens : Array[String]) -> Bool {
  let haystack = (skill.name + " " + skill.description).to_lower()
  for token in tokens {
    if !haystack.contains(token) {
      return false
    }
  }
  true
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
) -> @posoco.ToolOutcome {
  let values : Array[Json] = []
  let lines : Array[String] = []
  for skill in skills {
    values.push(skill_search_json(skill))
    lines.push(
      "\{skill.name}: \{unicode_scalar_preview(skill.description, SKILL_DESCRIPTION_PREVIEW_CHARS)}",
    )
  }
  let content = if skills.is_empty() {
    "(no skills)"
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
fn selected_skill_probability(
  probabilities : Array[@posoco.DecisionNamedProbability],
  selected : String,
) -> Double? {
  for entry in probabilities {
    if entry.id == selected {
      return Some(entry.probability)
    }
  }
  None
}

///|
async fn Skills::semantic_skill_match(
  self : Skills,
  query : String,
) -> SkillDescriptor? noraise {
  let decision = match self.decision {
    Some(decision) => decision
    None => return None
  }
  if self.catalog.skills.is_empty() {
    return None
  }
  if self.catalog.skills.length() == 1 {
    let skill = self.catalog.skills[0]
    let request : @posoco.DecisionRequest = {
      state: Json::object({
        "query": Json::string(query),
        "skill": skill_search_json(skill),
      }),
      questions: [
        @posoco.DecisionQuestion::Boolean(
          id="skills.relevance",
          instructions=Json::string(
            "Is this discovered skill semantically relevant to the user's task or capability query? Judge relevance only; do not activate the skill or grant authority.",
          ),
          true_criteria=None,
          false_criteria=None,
        ),
      ],
    }
    let result = decision.evaluate(request) catch { _ => return None }
    result.validate_for(request) catch {
      _ => return None
    }
    for answer in result.answers {
      match answer {
        @posoco.DecisionAnswer::BooleanAnswer(
          id="skills.relevance",
          probability_true~
        ) if probability_true >= SEMANTIC_SKILL_MIN_PROBABILITY =>
          return Some(skill)
        _ => ()
      }
    }
    return None
  }
  let options : Array[@posoco.DecisionOption] = []
  for skill in self.catalog.skills {
    options.push({
      id: skill.name,
      description: Some(skill_search_json(skill)),
    })
  }
  let request : @posoco.DecisionRequest = {
    state: Json::object({ "query": Json::string(query) }),
    questions: [
      @posoco.DecisionQuestion::Choice(
        id="skills.relevance",
        instructions=Json::string(
          "Choose the single discovered skill most semantically relevant to this task or capability query. Judge relevance only; do not activate the skill or grant authority.",
        ),
        options~,
      ),
    ],
  }
  let result = decision.evaluate(request) catch { _ => return None }
  result.validate_for(request) catch {
    _ => return None
  }
  for answer in result.answers {
    match answer {
      @posoco.DecisionAnswer::ChoiceAnswer(
        id="skills.relevance",
        selected~,
        probabilities~,
        ..
      ) =>
        match selected_skill_probability(probabilities, selected) {
          Some(probability) if probability >= SEMANTIC_SKILL_MIN_PROBABILITY =>
            return self.catalog.find(selected)
          _ => ()
        }
      _ => ()
    }
  }
  None
}

///|
async fn Skills::search(
  self : Skills,
  query : String,
) -> @posoco.ToolOutcome noraise {
  let tokens = skill_search_tokens(query)
  if tokens.is_empty() {
    return skill_search_success([], query)
  }
  let lexical : Array[SkillDescriptor] = []
  for skill in self.catalog.skills {
    if skill_matches_query(skill, tokens) && lexical.length() < 8 {
      lexical.push(skill)
    }
  }
  if !lexical.is_empty() {
    return skill_search_success(lexical, query)
  }
  match self.semantic_skill_match(query) {
    Some(skill) => skill_search_success([skill], query)
    None => skill_search_success([], query)
  }
}

///|
fn Skills::activate_tool_def(self : Skills) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(self.config.activate_tool_name),
    description: "Load one skill's instructions and list bundled resources. Use an exact discovered skill name.",
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object({
        "name": Json::object({
          "type": Json::string("string"),
          "description": Json::string("Exact skill name"),
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
    description: "Read one UTF-8 resource named by an activated skill. Path stays inside that skill directory.",
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
            "Path relative to skill directory",
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
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name == SKILL_SEARCH_TOOL_NAME {
    let query = require_string_arg(name, call.arguments, "query")
    if query.trim().is_empty() || query.length() > 4096 {
      raise @posoco.RuntimeError::InvocationFailed(
        name + ": 'query' must be 1..4096 chars",
      )
    }
    return self.search(query)
  }
  if name == self.config.activate_tool_name {
    let skill_name = require_string_arg(name, call.arguments, "name")
    if !runtime_skill_name_is_safe(skill_name) {
      raise @posoco.RuntimeError::InvocationFailed(
        name + ": invalid 'name'",
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
