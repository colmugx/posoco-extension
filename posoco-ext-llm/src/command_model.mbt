///|
/// `/model` command for the provider-catalog router.
///
/// With no argument the command returns a machine-readable slot catalog. With
/// a slot id it changes router selection. An optional `effort` field selects a
/// provider-advertised reasoning effort through the slot's rebuild hook.

///|
/// Machine-readable slot catalog. `quota` enriches each entry of a provider
/// that has readings under its id with a `quota_readings` array; the key is
/// omitted entirely when no quota map is given or the provider has none.
/// `pricing` enriches each entry of a provider whose registered source states
/// a phase with a `pricing` object; the key is omitted entirely when no
/// pricing map is given or the provider has none.
fn RouterModelPort::slot_catalog_json(
  self : RouterModelPort,
  quota? : Map[String, Array[@devkit.QuotaReading]]? = None,
  pricing? : Map[String, @devkit.PricingPhase]? = None,
) -> Json {
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
    let pairs : Array[(String, Json)] = [
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
      (
        "group",
        match slot.display_group {
          Some(value) => Json::string(value)
          None => Json::null()
        },
      ),
    ]
    match quota {
      Some(map) =>
        match map.get(slot.provider_id) {
          Some(readings) => {
            let reading_values : Array[Json] = []
            for reading in readings {
              reading_values.push(quota_reading_json(reading))
            }
            pairs.push(("quota_readings", Json::array(reading_values)))
          }
          None => ()
        }
      None => ()
    }
    match pricing {
      Some(map) =>
        match map.get(slot.provider_id) {
          Some(phase) => pairs.push(("pricing", pricing_phase_json(phase)))
          None => ()
        }
      None => ()
    }
    entries.push(Json::object(Map::from_array(pairs)))
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
  command : String,
  fields : Map[String, Json],
  key : String,
) -> String? raise @posoco.CommandError {
  match fields.get(key) {
    None => None
    Some(Json::String(value)) =>
      if value.length() == 0 {
        raise @posoco.CommandError::InvalidArgs(
          reason=command + " " + key + " must be a non-empty string",
        )
      } else {
        Some(value)
      }
    Some(_) =>
      raise @posoco.CommandError::InvalidArgs(
        reason=command + " " + key + " must be a string",
      )
  }
}

///|
fn model_command_selection(
  args : Json,
) -> ModelSelection raise @posoco.CommandError {
  match args {
    Json::Null => { slot_id: None, effort: None, }
    Json::String(slot_id) =>
      if slot_id.length() == 0 {
        { slot_id: None, effort: None, }
      } else {
        { slot_id: Some(slot_id), effort: None, }
      }
    Json::Object(fields) =>
      {
        slot_id: parse_optional_string("/model", fields, "slot"),
        effort: parse_optional_string("/model", fields, "effort"),
      }
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/model expects no arguments, a slot string, or {slot, effort}",
      )
  }
}

///|
/// Parse `/effort` arguments. Accepts no arguments (query the active slot),
/// a bare effort string, or an object carrying either `effort` or the
/// `_positional` string a host slash parser produces.
fn effort_command_selection(args : Json) -> String? raise @posoco.CommandError {
  match args {
    Json::Null => None
    Json::String(value) => if value.length() == 0 { None } else { Some(value) }
    Json::Object(fields) =>
      match parse_optional_string("/effort", fields, "effort") {
        Some(value) => Some(value)
        None => parse_optional_string("/effort", fields, "_positional")
      }
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/effort expects no arguments or an effort string",
      )
  }
}

///|
/// Select a provider-advertised reasoning effort on one slot through its
/// rebuild hook. Public so hosts can restore a persisted effort at composition
/// and apply ACP/config-driven effort switches; the `/effort` command remains
/// the interactive entry point.
pub fn RouterModelPort::select_effort(
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
  let slot_choices : Array[String] = [quick_pick_keyword]
  for id in self.list_slot_ids() {
    slot_choices.push(id)
  }
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
          description: "Target slot id; `quick-pick` ranks models by remaining quota; `<provider> pick` auto-picks by intelligence-per-dollar metrics; omit to list available models",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: Some(slot_choices),
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
    @posoco.CommandDef::{
      id: "effort",
      label: "Switch Effort",
      description: "Show or switch reasoning effort for the active model slot",
      category: "model",
      ctype: @posoco.CommandType::Select,
      params: [
        @posoco.CommandParam::{
          name: "effort",
          label: "Effort",
          description: "Provider-advertised reasoning effort; omit to show the current effort",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: match self.slots.get(self.active_id) {
            Some(slot) => Some(slot.thinking_efforts.copy())
            None => Some([])
          },
          positional: true,
        },
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
    @posoco.CommandDef::{
      id: "status",
      label: "Status",
      description: "Active provider status: model, context window, quota windows",
      category: "model",
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
pub impl @posoco.CommandPort for RouterModelPort with fn invoke(
  self : RouterModelPort,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "model" =>
      match model_command_selection(args) {
        { slot_id: None, effort: None, } =>
          @posoco.CommandOutcome::Success(
            feedback="Available model slots",
            structured=Some(
              self.slot_catalog_json(
                pricing=Some(self.collect_provider_pricing()),
              ),
            ),
            ui_hint=Some(@posoco.UiHint::RefreshModelList),
          )
        { slot_id: Some(slot_id), effort, } =>
          if slot_id == quick_pick_keyword {
            match effort {
              Some(_) =>
                @posoco.CommandOutcome::Failure(
                  reason="/model quick-pick takes no effort",
                )
              None => {
                let readings = self.collect_provider_quota()
                // Mirror /status: a successful pull for the active provider
                // doubles as the bar refresh.
                match readings.get(self.current_provider_id()) {
                  Some(list) => {
                    self.quota_readings = list
                    self.quota_fetched_at = @async.now()
                    self.publish_quota_segments()
                  }
                  None => ()
                }
                @posoco.CommandOutcome::Success(
                  feedback="Quick-pick model slots",
                  structured=Some(self.slot_catalog_json(quota=Some(readings))),
                  ui_hint=Some(@posoco.UiHint::RefreshModelList),
                )
              }
            }
          } else if !self.slots.contains(slot_id) &&
            effort == Some(pick_keyword) {
            // `/model <provider> pick`: the id is not a slot but names a
            // provider with a registered metrics source. Real slots always
            // win over this intercept.
            match @devkit.metrics_registry_lookup(slot_id) {
              Some(source) =>
                self.run_provider_pick(slot_id, source) catch {
                  err =>
                    return @posoco.CommandOutcome::Failure(
                      reason=err.to_string(),
                    )
                }
              None =>
                @posoco.CommandOutcome::Failure(
                  reason="no metrics source registered for provider '" +
                    slot_id +
                    "'",
                )
            }
          } else if !self.slots.contains(slot_id) {
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
            self.publish_model_status()
            self.publish_provider_event()
            // Immediate probe so the bar reflects the new provider's quota
            // as soon as the command returns.
            self.refresh_quota_now()
            @posoco.CommandOutcome::Success(
              feedback="switched to model slot: " + slot_id,
              structured=Some(self.slot_catalog_json()),
              ui_hint=Some(@posoco.UiHint::RefreshModelList),
            )
          }
        { slot_id: None, effort: Some(_), } =>
          @posoco.CommandOutcome::Failure(
            reason="/model effort requires a slot",
          )
      }
    "effort" =>
      match effort_command_selection(args) {
        None => {
          let slot = self.active_slot()
          let current = match self.active_effort {
            Some(value) => Some(value)
            None => slot.default_effort
          }
          let feedback = match current {
            Some(value) =>
              "current effort: " + value + " (" + self.active_id + ")"
            None => "model slot has no effort selection: " + self.active_id
          }
          @posoco.CommandOutcome::Success(
            feedback~,
            structured=Some(self.slot_catalog_json()),
            ui_hint=Some(@posoco.UiHint::None),
          )
        }
        Some(level) => {
          let slot = self.active_slot()
          if slot.thinking_efforts.is_empty() {
            @posoco.CommandOutcome::Failure(
              reason="model slot does not support effort selection: " +
                self.active_id,
            )
          } else {
            self.select_effort(self.active_id, level) catch {
              err =>
                return @posoco.CommandOutcome::Failure(reason=err.to_string())
            }
            self.publish_model_status()
            self.publish_provider_event()
            // Immediate probe: the switch may land on a different provider.
            self.refresh_quota_now()
            @posoco.CommandOutcome::Success(
              feedback="switched effort: " + level + " (" + self.active_id + ")",
              structured=Some(self.slot_catalog_json()),
              ui_hint=Some(@posoco.UiHint::RefreshModelList),
            )
          }
        }
      }
    "status" => {
      expect_no_args(args)
      // Command-triggered live pull from the active provider's registered
      // quota source: the source applies its own timeout; Err states the
      // reading is unavailable and is skipped, never estimated.
      let now = @async.now()
      let readings : Array[@devkit.QuotaReading] = match
        @devkit.quota_registry_lookup(self.current_provider_id()) {
        Some(source) => {
          let result = source.read() catch { _ => Err("quota pull failed") }
          match result {
            Ok(list) => {
              // The live pull doubles as the bar refresh: cache what
              // /status fetched so the statusbar segments stay in sync
              // with this report.
              self.quota_readings = list
              self.quota_fetched_at = now
              self.publish_quota_segments()
              list
            }
            Err(_) => {
              // A failed pull backs off like the chat path and keeps the
              // published segments: a failed /status never retracts bar
              // data that was already there.
              self.quota_failed_at = now
              []
            }
          }
        }
        None => []
      }
      let (feedback, structured) = self.status_report(readings~)
      @posoco.CommandOutcome::Success(
        feedback~,
        structured=Some(structured),
        ui_hint=Some(@posoco.UiHint::None),
      )
    }
    "login" => self.invoke_login(args)
    other => raise @posoco.CommandError::NotFound(other)
  }
}
