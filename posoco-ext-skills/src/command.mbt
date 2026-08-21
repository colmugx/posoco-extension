///|
/// Host-facing `skills` command: panel/slash/autocomplete consumers call the
/// default `list` action, which reads only the in-memory catalog snapshot
/// taken at composition — zero filesystem IO, safe to call per keystroke.
/// `activate` is the user-invocation path (for example a `$name` mention) and
/// re-reads SKILL.md through the same guarded activation checks as the
/// model-facing tool.
pub impl @posoco.CommandPort for Skills with fn commands(_self : Skills) -> Array[
  @posoco.CommandDef,
] {
  [
    @posoco.CommandDef::{
      id: "skills",
      label: "Skills",
      description: "List available agent skills with their scope (project/user/extra)",
      category: "skills",
      ctype: @posoco.CommandType::Action,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
/// User-facing scope label. The prompt contributor says "repository" because
/// that is the discovery term; hosts and humans say "project".
fn scope_label(scope : SkillScope) -> String {
  match scope {
    Repository => "project"
    User => "user"
    Extra(_) => "extra"
  }
}

///|
fn count_scope(skills : Array[SkillDescriptor], scope : String) -> Int {
  let mut count = 0
  for skill in skills {
    if scope_label(skill.scope) == scope {
      count = count + 1
    }
  }
  count
}

///|
fn Skills::command_list(self : Skills) -> @posoco.CommandOutcome {
  let entries : Array[Json] = []
  for skill in self.catalog.skills {
    let fields : Array[(String, Json)] = [
      ("name", Json::string(skill.name)),
      ("description", Json::string(skill.description)),
      ("scope", Json::string(scope_label(skill.scope))),
    ]
    match skill.scope {
      Extra(root) => fields.push(("root", Json::string(root)))
      _ => ()
    }
    entries.push(Json::object(Map::from_array(fields)))
  }
  let feedback = if self.catalog.skills.is_empty() {
    "no skills discovered"
  } else {
    let total = self.catalog.skills.length()
    let project = count_scope(self.catalog.skills, "project")
    let user = count_scope(self.catalog.skills, "user")
    let extra = count_scope(self.catalog.skills, "extra")
    "\{total} skills (project \{project}, user \{user}, extra \{extra})"
  }
  @posoco.CommandOutcome::Success(
    feedback~,
    structured=Some(
      Json::object(
        Map::from_array([
          ("kind", Json::string("skills_catalog")),
          ("skills", Json::array(entries)),
        ]),
      ),
    ),
    ui_hint=Some(@posoco.UiHint::None),
  )
}

///|
async fn Skills::command_activate(
  self : Skills,
  name : String,
) -> @posoco.CommandOutcome noraise {
  if name.trim().is_empty() {
    return @posoco.CommandOutcome::Failure(
      reason="skills: activate requires a non-empty skill name",
    )
  }
  match self.activate_skill(name) {
    @posoco.ToolOutcome::Success(content~, ..) =>
      @posoco.CommandOutcome::Success(
        feedback="activated skill: " + name,
        structured=Some(
          Json::object(
            Map::from_array([
              ("kind", Json::string("agent_skill_activation")),
              ("name", Json::string(name)),
              ("instructions", Json::string(content)),
            ]),
          ),
        ),
        ui_hint=Some(@posoco.UiHint::None),
      )
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      @posoco.CommandOutcome::Failure(reason=content)
    _ =>
      @posoco.CommandOutcome::Failure(
        reason="skills: activation failed for '" + name + "'",
      )
  }
}

///|
pub impl @posoco.CommandPort for Skills with fn invoke(
  self : Skills,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  if id != "skills" {
    raise @posoco.CommandError::NotFound(id)
  }
  let (action, name) : (String, String?) = match args {
    Json::Object(fields) => {
      let action = match fields.get("action") {
        None => "list"
        Some(Json::String(value)) => value
        Some(_) =>
          raise @posoco.CommandError::InvalidArgs(
            reason="skills: 'action' must be a string",
          )
      }
      let name = match fields.get("name") {
        None => None
        Some(Json::String(value)) => Some(value)
        Some(_) =>
          raise @posoco.CommandError::InvalidArgs(
            reason="skills: 'name' must be a string",
          )
      }
      (action, name)
    }
    Json::Null => ("list", None)
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="skills: arguments must be a JSON object",
      )
  }
  match action {
    "list" => self.command_list()
    "activate" =>
      match name {
        Some(value) => self.command_activate(value)
        None =>
          @posoco.CommandOutcome::Failure(
            reason="skills: activate requires a 'name' argument",
          )
      }
    other =>
      @posoco.CommandOutcome::Failure(
        reason="skills: unknown action '" +
          other +
          "' (expected list or activate)",
      )
  }
}

///|
pub extend Skills with @posoco.CommandPort::{commands, invoke}
