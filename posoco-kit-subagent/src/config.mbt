///|
/// Numeric bundle of subagent-config.json. Defaults live
/// in `SubagentConfig::defaults`.
pub(all) struct SubagentLimits {
  swarm_items : Int
  concurrency : Int
  global_concurrency : Int
  timeout_ms : Int
  spawn_budget : Int
} derive(Eq, @debug.Debug)

///|
pub extend SubagentLimits with Eq::{not_equal, equal}

///|
pub extend SubagentLimits with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Parsed subagent-config. `default_model` (with optional `default_effort`)
/// routes every kind that does not bind its own model; absent → subagents
/// inherit the parent's live selection. Model bindings themselves live on
/// kinds (frontmatter or settings entries), not here.
pub(all) struct SubagentConfig {
  default_model : String?
  default_effort : String?
  limits : SubagentLimits
} derive(Eq, @debug.Debug)

///|
pub extend SubagentConfig with Eq::{not_equal, equal}

///|
pub extend SubagentConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Config failures. `Malformed` marks wrong shapes/types, `Invalid`
/// semantically out-of-range values (empty strings).
pub(all) suberror SubagentConfigError {
  /// Not valid JSON, or the JSON shape/types are wrong.
  Malformed(String)
  /// Valid JSON but semantically out of range (empty strings).
  Invalid(String)
}

///|
/// Conservative defaults: no default model (inherit the parent), swarm items
/// 16, group concurrency 4, global concurrency 20, timeout 30 minutes,
/// spawn budget 64.
pub fn SubagentConfig::defaults() -> SubagentConfig {
  {
    default_model: None,
    default_effort: None,
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
/// Parse subagent-config JSON text. All top-level keys are optional: a config
/// with none of them parses to `defaults()`. Unknown keys are ignored; wrong
/// types and empty strings raise instead of being repaired.
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
  let default_model : String? = match fields.get("default_model") {
    None => None
    Some(String(model)) =>
      if model.is_empty() {
        raise SubagentConfigError::Invalid(
          "'default_model' must be a non-empty string",
        )
      } else {
        Some(model)
      }
    Some(_) =>
      raise SubagentConfigError::Malformed("'default_model' must be a string")
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
  let limits = match fields.get("limits") {
    None => SubagentConfig::defaults().limits
    Some(Object(limit_fields)) => parse_limits(limit_fields)
    Some(_) =>
      raise SubagentConfigError::Malformed("'limits' must be an object")
  }
  { default_model, default_effort, limits, }
}

///|
/// One limits field: absent falls back to the default; present must be an
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
