///|
/// The `activate_profile` meta tool: the model's self-activation path (Q2).
/// The result text is contract, not prose — `header.mbt`'s pending scanner
/// consumes the `activated: <id>` / `unknown profile: <id>` first lines
/// (frozen prefixes; keep both sides in sync).

///|
/// The one model-visible meta tool. The description teaches menu-driven
/// selection, the same-turn effect, idempotence, and the `all` fallback.
fn activate_profile_def() -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked("activate_profile"),
    description: "Activate a profile from the Profiles menu in the system prompt. Activation injects the profile's manual with the next model request and takes effect within the current turn; activating an already-active profile adds nothing. When no profile fits the task, activate the fallback id `all`.",
    input_schema: Json::object(
      Map::from_array([
        ("type", Json::string("object")),
        (
          "properties",
          Json::object(
            Map::from_array([
              (
                "profile",
                Json::object(
                  Map::from_array([
                    ("type", Json::string("string")),
                    (
                      "description",
                      Json::string(
                        "Profile id exactly as listed in the Profiles menu",
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        ("required", Json::array([Json::string("profile")])),
      ]),
    ),
    owner: @posoco.OwnerId::unchecked("posoco_ext_profiles"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("posoco_ext_profiles"),
  }
}

///|
/// Port contribution: exactly one meta tool.
pub impl @posoco.ToolProvider for Profiles with fn list_tools(_self : Profiles) -> Array[
  @posoco.ToolDef,
] {
  [activate_profile_def()]
}

///|
/// Route the activation call. No session state is read or written here
/// (Q18): the result text only announces what the before_model hook will
/// inject; the activation knowledge lives in the hook.
pub impl @posoco.ToolProvider for Profiles with fn execute(
  self : Profiles,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if name != "activate_profile" {
    raise @posoco.RuntimeError::UnknownTool(
      "posoco_ext_profiles: no tool named '\{name}'",
    )
  }
  let requested = match call.arguments {
    Json::Object(fields) =>
      match fields.get("profile") {
        Some(Json::String(id)) => Some(id)
        _ => None
      }
    _ => None
  }
  let id = match requested {
    Some(id) => id
    None =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="activate_profile requires {\"profile\": \"<id>\"}",
        structured=None,
      )
  }
  match self.find_entry(id) {
    Some(_) =>
      // F7 wording (Q18): the manual rides the next model request — the
      // model must NOT end the turn to wait for another user message.
      @posoco.ToolOutcome::Success(
        content="activated: \{id}\n\nThe '\{id}' manual is injected with the next model request and takes effect within this turn — no further user message is needed.",
        structured=None,
      )
    None =>
      // Unknown id: explicit never-inject verdict plus the menu mirror
      // (Q16), `all` included.
      @posoco.ToolOutcome::Success(
        content="unknown profile: \{id}\navailable: \{self.available_ids().join(", ")}",
        structured=None,
      )
  }
}
