///|
/// One configured model slot (design §6.4): a router slot plus the reasoning
/// efforts it offers. `efforts` empty means the slot accepts any effort;
/// `default_effort` is returned when the caller picks the slot without an
/// effort.
pub(all) struct ConfigModel {
  slot : String
  efforts : Array[String]
  default_effort : String?
} derive(Eq, @debug.Debug)

///|
/// Numeric bundle of subagent-config.json (design §6.4, §9.2). Defaults live
/// in `SubagentConfig::defaults`.
pub(all) struct SubagentLimits {
  swarm_items : Int
  concurrency : Int
  global_concurrency : Int
  timeout_ms : Int
  spawn_budget : Int
} derive(Eq, @debug.Debug)

///|
/// Parsed subagent-config.json. `models` empty = inheritance mode: the
/// caller's explicit model/effort pass through unvalidated, and absent values
/// fall back to the parent's active selection.
pub(all) struct SubagentConfig {
  models : Array[ConfigModel]
  default_slot : String?
  limits : SubagentLimits
} derive(Eq, @debug.Debug)

///|
/// Config failures. The message text is model-facing: `Invalid` messages list
/// the allowed slots/efforts so the calling model can re-pick on its own.
pub(all) suberror SubagentConfigError {
  /// Not valid JSON, or the JSON shape/types are wrong.
  Malformed(String)
  /// Valid JSON but semantically out of range (duplicate or empty slot,
  /// unknown model slot, unavailable effort, missing default_slot).
  Invalid(String)
}

///|
/// Conservative numeric bundle from design §9.2: swarm items 16, group
/// concurrency 4, global concurrency 20, timeout 30 minutes, spawn budget 64.
pub fn SubagentConfig::defaults() -> SubagentConfig {
  {
    models: [],
    default_slot: None,
    limits: {
      swarm_items: 16,
      concurrency: 4,
      global_concurrency: 20,
      timeout_ms: 1800000,
      spawn_budget: 64,
    },
  }
}

///|
/// Parse subagent-config.json text. All top-level keys are optional: a config
/// with none of them parses to `defaults()`. Unknown keys are ignored; wrong
/// types, duplicate slots, and empty slot strings raise instead of being
/// repaired.
pub fn parse_subagent_config(
  text : String,
) -> SubagentConfig raise SubagentConfigError {
  let root : Json = @json.parse(text) catch {
    _ =>
      raise SubagentConfigError::Malformed("subagent config is not valid JSON")
  }
  let fields = match root {
    Object(fields) => fields
    _ =>
      raise SubagentConfigError::Malformed(
        "subagent config must be a JSON object",
      )
  }
  let models : Array[ConfigModel] = match fields.get("models") {
    None => []
    Some(Array(items)) => {
      let out : Array[ConfigModel] = []
      for item in items {
        out.push(parse_config_model(item))
      }
      out
    }
    Some(_) => raise SubagentConfigError::Malformed("'models' must be an array")
  }
  check_duplicate_slots(models)
  let default_slot : String? = match fields.get("default_slot") {
    None => None
    Some(String(slot)) =>
      if slot.is_empty() {
        raise SubagentConfigError::Invalid(
          "'default_slot' must be a non-empty string",
        )
      } else {
        Some(slot)
      }
    Some(_) =>
      raise SubagentConfigError::Malformed("'default_slot' must be a string")
  }
  let limits = match fields.get("limits") {
    None => SubagentConfig::defaults().limits
    Some(Object(limit_fields)) => parse_limits(limit_fields)
    Some(_) =>
      raise SubagentConfigError::Malformed("'limits' must be an object")
  }
  { models, default_slot, limits, }
}

///|
fn parse_config_model(value : Json) -> ConfigModel raise SubagentConfigError {
  let fields = match value {
    Object(fields) => fields
    _ =>
      raise SubagentConfigError::Malformed("'models' entries must be objects")
  }
  let slot = match fields.get("slot") {
    Some(String(slot)) =>
      if slot.is_empty() {
        raise SubagentConfigError::Invalid("'slot' must be a non-empty string")
      } else {
        slot
      }
    _ =>
      raise SubagentConfigError::Malformed(
        "'models[].slot' must be a non-empty string",
      )
  }
  let efforts : Array[String] = match fields.get("efforts") {
    None => []
    Some(Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          String(effort) =>
            if effort.is_empty() {
              raise SubagentConfigError::Invalid(
                "'efforts' entries must be non-empty strings",
              )
            } else {
              out.push(effort)
            }
          _ =>
            raise SubagentConfigError::Malformed(
              "'efforts' entries must be strings",
            )
        }
      }
      out
    }
    Some(_) =>
      raise SubagentConfigError::Malformed(
        "'efforts' must be an array of strings",
      )
  }
  let default_effort : String? = match fields.get("default_effort") {
    None => None
    Some(String(effort)) =>
      if effort.is_empty() {
        raise SubagentConfigError::Invalid(
          "'default_effort' must be a non-empty string",
        )
      } else {
        Some(effort)
      }
    Some(_) =>
      raise SubagentConfigError::Malformed("'default_effort' must be a string")
  }
  { slot, efforts, default_effort, }
}

///|
fn check_duplicate_slots(
  models : Array[ConfigModel],
) -> Unit raise SubagentConfigError {
  let seen : Set[String] = Set([])
  for model in models {
    if seen.contains(model.slot) {
      raise SubagentConfigError::Invalid("duplicate model slot '\{model.slot}'")
    }
    seen.add(model.slot)
  }
}

///|
/// One limits field: absent falls back to the §9.2 default; present must be an
/// integral number (a fractional value is a type error, not a truncation).
fn limits_int(
  fields : Map[String, Json],
  key : String,
  fallback : Int,
) -> Int raise SubagentConfigError {
  match fields.get(key) {
    None => fallback
    Some(Number(value, ..)) => {
      let whole = value.to_int()
      if value != whole.to_double() {
        raise SubagentConfigError::Malformed(
          "'limits.\{key}' must be an integer",
        )
      }
      whole
    }
    Some(_) =>
      raise SubagentConfigError::Malformed("'limits.\{key}' must be a number")
  }
}

///|
fn parse_limits(
  fields : Map[String, Json],
) -> SubagentLimits raise SubagentConfigError {
  let base = SubagentConfig::defaults().limits
  {
    swarm_items: limits_int(fields, "swarm_items", base.swarm_items),
    concurrency: limits_int(fields, "concurrency", base.concurrency),
    global_concurrency: limits_int(
      fields,
      "global_concurrency",
      base.global_concurrency,
    ),
    timeout_ms: limits_int(fields, "timeout_ms", base.timeout_ms),
    spawn_budget: limits_int(fields, "spawn_budget", base.spawn_budget),
  }
}

///|
/// The model selection a subagent spawn should use. With `models` empty the
/// config opens no range: explicit values pass through as-is (platform-side
/// validation is the caller's job) and absent values inherit the parent's
/// active selection.
pub(all) struct ResolvedSelection {
  slot : String
  effort : String?
} derive(Eq, @debug.Debug)

///|
/// Resolve the spawn-time `model`/`effort` overrides against the configured
/// range (design §6.4). With configured models, the explicit model must name
/// a configured slot and the effort must be offered by that slot; a model
/// without an effort gets the entry's `default_effort`; no model falls back
/// to `default_slot`. `parent_*` is used only in inheritance mode. Error
/// messages list the allowed options so the calling model can re-pick.
pub fn SubagentConfig::resolve(
  self : SubagentConfig,
  model? : String? = None,
  effort? : String? = None,
  parent_slot~ : String,
  parent_effort? : String? = None,
) -> ResolvedSelection raise SubagentConfigError {
  if self.models.is_empty() {
    let slot = match model {
      Some(explicit) => explicit
      None => parent_slot
    }
    let resolved_effort = match effort {
      Some(explicit) => Some(explicit)
      None => parent_effort
    }
    return { slot, effort: resolved_effort, }
  }
  let entry = match model {
    Some(explicit) =>
      match find_slot(self.models, explicit) {
        Some(entry) => entry
        None =>
          raise SubagentConfigError::Invalid(
            "unknown subagent model '\{explicit}' (allowed slots: \{allowed_slots(self.models)})",
          )
      }
    None =>
      match self.default_slot {
        Some(default) =>
          match find_slot(self.models, default) {
            Some(entry) => entry
            None =>
              raise SubagentConfigError::Invalid(
                "default_slot '\{default}' is not among the configured models (allowed slots: \{allowed_slots(self.models)})",
              )
          }
        None =>
          raise SubagentConfigError::Invalid(
            "no model given and no default_slot configured (allowed slots: \{allowed_slots(self.models)})",
          )
      }
  }
  let resolved_effort = match effort {
    Some(explicit) => {
      if !entry.efforts.is_empty() && !entry.efforts.contains(explicit) {
        raise SubagentConfigError::Invalid(
          "effort '\{explicit}' is not available for slot '\{entry.slot}' (allowed efforts: \{entry.efforts.join(", ")})",
        )
      }
      Some(explicit)
    }
    None => entry.default_effort
  }
  { slot: entry.slot, effort: resolved_effort, }
}

///|
fn find_slot(models : Array[ConfigModel], slot : String) -> ConfigModel? {
  for model in models {
    if model.slot == slot {
      return Some(model)
    }
  }
  None
}

///|
/// Slots in config order (order of appearance; deliberately no string sort).
fn allowed_slots(models : Array[ConfigModel]) -> String {
  let names : Array[String] = []
  for model in models {
    names.push(model.slot)
  }
  names.join(", ")
}
