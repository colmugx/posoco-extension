///|
/// Per-model reasoning surfaces for the OpenCode Zen gateway, decoded from
/// models.dev — the `opencode` provider entry of the OpenCode mirror at
/// <https://models.opencode.ai/api.json>, the same catalog OpenCode itself
/// reads.
///
/// Zen's own `/models` listing publishes no capability fields (only
/// `{id, object, created, owned_by}`), so this mirror is the only source of
/// the picker's effort vocabulary. Three shapes occur per model:
///
/// - `reasoning: false` — a plain chat model: no selector at all.
/// - `reasoning: true` with declared effort levels — the levels pass through
///   verbatim (`none` included when models.dev lists it); `off` joins the
///   picker when thinking can be disabled (a `{type:"toggle"}` option, or
///   `none` among the levels).
/// - `reasoning: true` without levels (toggle-only, budget tokens, empty or
///   missing `reasoning_options`) — a bare `off` / `on` toggle.
///
/// A model absent from the decoded map — metadata unavailable, or the refresh
/// fetch degraded to an empty map — presents the safe fallback picker
/// (`off` / `on`, thinking off), so a stale or failed lookup never produces a
/// selector the gateway would reject a level from.

///|
/// One model's reasoning surface as models.dev describes it: whether the
/// model reasons at all, the selectable effort levels (empty for a bare
/// toggle), and whether thinking can be switched off ("off" in the picker).
pub(all) struct ZenReasoningSurface {
  reasoning : Bool
  levels : Array[String]
  can_disable : Bool
} derive(Eq, Debug)

///|
pub extend ZenReasoningSurface with Eq::{not_equal, equal}

///|
pub extend ZenReasoningSurface with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Decode the models.dev provider catalog into per-model reasoning surfaces,
/// keyed by bare model id. The payload must be an object holding the
/// `opencode` provider with a `models` object — anything else is a typed
/// parse failure. A single malformed model entry is skipped, never fatal: the
/// surface is picker enrichment, not a wire contract.
pub fn parse_models_dev_surfaces(
  payload : Json,
) -> Map[String, ZenReasoningSurface] raise @posoco.ModelError {
  let root = match payload {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "models.dev response must be an object",
      )
  }
  let provider = match root.get("opencode") {
    Some(Json::Object(fields)) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "models.dev response is missing the opencode provider object",
      )
  }
  let models = match provider.get("models") {
    Some(Json::Object(fields)) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "models.dev opencode provider must carry a models object",
      )
  }
  let surfaces : Map[String, ZenReasoningSurface] = Map::from_array([])
  for id, entry in models {
    let fields = match entry {
      Json::Object(fields) => fields
      _ => continue
    }
    let reasoning = match fields.get("reasoning") {
      Some(Json::True) => true
      _ => false
    }
    let levels : Array[String] = []
    let mut can_disable = false
    let mut effort_seen = false
    match fields.get("reasoning_options") {
      Some(Json::Array(options)) =>
        for option in options {
          let option_fields = match option {
            Json::Object(option_fields) => option_fields
            _ => continue
          }
          match option_fields.get("type") {
            Some(Json::String("toggle")) => can_disable = true
            Some(Json::String("effort")) =>
              // Only the first effort option counts, mirroring opencode's
              // own reasoningVariants precedence.
              if !effort_seen {
                effort_seen = true
                match option_fields.get("values") {
                  Some(Json::Array(values)) =>
                    for value in values {
                      match value {
                        Json::String(level) => levels.push(level)
                        // The generic models.dev schema may emit a null
                        // level; opencode reads it back as "none".
                        Json::Null => levels.push("none")
                        _ => ()
                      }
                    }
                  _ => ()
                }
              }
            _ => ()
          }
        }
      _ => ()
    }
    if levels.contains("none") {
      can_disable = true
    }
    surfaces[id] = { reasoning, levels, can_disable, }
  }
  surfaces
}

///|
/// The effort a level-bearing surface starts on: "high" when the model offers
/// it, otherwise the first declared level (e.g. "max" for kimi-k3).
fn zen_preset_default_level(levels : Array[String]) -> String {
  if levels.contains("high") {
    "high"
  } else {
    levels[0]
  }
}
