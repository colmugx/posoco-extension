///|
/// `/model` command for the provider-catalog router.
///
/// With no argument the command returns a machine-readable slot catalog. With
/// a slot id it changes router selection. An optional `effort` field selects a
/// provider-advertised reasoning effort through the slot's rebuild hook.

///|
fn RouterModelPort::slot_catalog_json(self : RouterModelPort) -> Json {
  let entries : Array[Json] = []
  for slot in self.list_slots() {
    let effort_values : Array[Json] = []
    for effort in slot.thinking_efforts {
      effort_values.push(Json::string(effort))
    }
    let capability_values : Array[Json] = []
    for capability in slot.capabilities {
      capability_values.push(Json::string(capability))
    }
    entries.push(
      Json::object(
        Map::from_array([
          ("id", Json::string(slot.id)),
          ("label", Json::string(slot.label)),
          ("provider", Json::string(slot.provider_id)),
          ("model", Json::string(slot.model_id)),
          ("active", Json::boolean(slot.id == self.active_id)),
          (
            "active_effort",
            match self.active_effort {
              Some(effort) => Json::string(effort)
              None => Json::null()
            },
          ),
          ("thinking_efforts", Json::array(effort_values)),
          (
            "context_window",
            match slot.context_window {
              Some(value) => Json::number(value.to_double())
              None => Json::null()
            },
          ),
          ("capabilities", Json::array(capability_values)),
          (
            "default_effort",
            match slot.default_effort {
              Some(value) => Json::string(value)
              None => Json::null()
            },
          ),
        ]),
      ),
    )
  }
  Json::array(entries)
}

///|
priv struct ModelSelection {
  slot_id : String?
  effort : String?
}

///|
fn parse_optional_string(
  fields : Map[String, Json],
  key : String,
) -> String? raise @posoco.CommandError {
  match fields.get(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CommandError::InvalidArgs(
          reason="/model " + key + " must be a non-empty string",
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/model " + key + " must be a string",
      )
  }
}

///|
fn model_command_selection(
  args : Json,
) -> ModelSelection raise @posoco.CommandError {
  match args {
    Json::Null => { slot_id: None, effort: None }
    Json::String(slot_id) =>
      if slot_id.length() == 0 {
        { slot_id: None, effort: None }
      } else {
        { slot_id: Some(slot_id), effort: None }
      }
    Json::Object(fields) =>
      {
        slot_id: parse_optional_string(fields, "slot"),
        effort: parse_optional_string(fields, "effort"),
      }
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/model expects no arguments, a slot string, or {slot, effort}",
      )
  }
}

///|
fn RouterModelPort::select_effort(
  self : RouterModelPort,
  slot_id : String,
  effort : String,
) -> Unit raise @posoco.CommandError {
  let slot = match self.slots.get(slot_id) {
    Some(slot) => slot
    None =>
      raise @posoco.CommandError::InvalidArgs(
        reason="unknown model slot: " + slot_id,
      )
  }
  if !slot.thinking_efforts.contains(effort) {
    raise @posoco.CommandError::InvalidArgs(
      reason="unsupported effort '" + effort + "' for model slot " + slot_id,
    )
  }
  match slot.rebuild_on_effort {
    Some(rebuild) => self.slots[slot_id] = rebuild(effort)
    None =>
      raise @posoco.CommandError::ExecutionFailed(
        "model slot does not expose an effort selector: " + slot_id,
      )
  }
  self.active_effort = Some(effort)
}

///|
pub impl @posoco.CommandPort for RouterModelPort with fn commands(
  self : RouterModelPort,
) -> Array[@posoco.CommandDef] {
  [
    @posoco.CommandDef::{
      id: "model",
      label: "Switch Model",
      description: "Switch the active model slot and optional effort",
      category: "model",
      ctype: @posoco.CommandType::Select,
      params: [
        @posoco.CommandParam::{
          name: "slot",
          label: "Model",
          description: "Target slot id; omit to list available models",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: Some(self.list_slot_ids()),
          positional: true,
        },
        @posoco.CommandParam::{
          name: "effort",
          label: "Effort",
          description: "Provider-advertised reasoning effort",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: match self.slots.get(self.active_id) {
            Some(slot) => Some(slot.thinking_efforts.copy())
            None => Some([])
          },
          positional: false,
        },
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
    @posoco.CommandDef::{
      id: "login",
      label: "Login",
      description: "Authenticate with a provider through its OAuth hook",
      category: "auth",
      ctype: @posoco.CommandType::Action,
      params: [
        @posoco.CommandParam::{
          name: "provider",
          label: "Provider",
          description: "Provider id; omit to list authentication methods",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: None,
          positional: true,
        },
        @posoco.CommandParam::{
          name: "method",
          label: "Method",
          description: "Provider-owned authentication method",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: Some(["api_key", "oauth"]),
          positional: false,
        },
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
pub impl @posoco.CommandPort for RouterModelPort with fn invoke(
  self : RouterModelPort,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "model" =>
      match model_command_selection(args) {
        { slot_id: None, effort: None } =>
          @posoco.CommandOutcome::Success(
            feedback="Available model slots",
            structured=Some(self.slot_catalog_json()),
            ui_hint=Some(@posoco.UiHint::RefreshModelList),
          )
        { slot_id: Some(slot_id), effort } =>
          if !self.slots.contains(slot_id) {
            @posoco.CommandOutcome::Failure(
              reason="unknown model slot: " + slot_id,
            )
          } else {
            match effort {
              Some(value) =>
                self.select_effort(slot_id, value) catch {
                  err =>
                    return @posoco.CommandOutcome::Failure(
                      reason=err.to_string(),
                    )
                }
              None => self.active_effort = None
            }
            self.active_id = slot_id
            @posoco.CommandOutcome::Success(
              feedback="switched to model slot: " + slot_id,
              structured=Some(self.slot_catalog_json()),
              ui_hint=Some(@posoco.UiHint::RefreshModelList),
            )
          }
        { slot_id: None, effort: Some(_) } =>
          @posoco.CommandOutcome::Failure(
            reason="/model effort requires a slot",
          )
      }
    "login" => self.invoke_login(args)
    other => raise @posoco.CommandError::NotFound(other)
  }
}
