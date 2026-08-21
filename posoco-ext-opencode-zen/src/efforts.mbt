///|
/// Curated per-model reasoning presets for the OpenCode Zen gateway.
///
/// Zen's own `/models` listing publishes no capability fields (only
/// `{id, object, created, owned_by}`), and neither does the host cache. The
/// selectable effort levels are therefore provider knowledge curated here,
/// mirroring the canonical source OpenCode itself uses: the `opencode`
/// provider's `reasoning_options` in <https://models.dev/api.json> (a
/// `{type:"toggle"}` entry means thinking can be switched off; a
/// `{type:"effort", values:[...]}` entry lists the selectable levels).
///
/// A model absent from the table is a plain chat model: no effort selector,
/// and the request omits the reasoning surface entirely (the gateway applies
/// the model's own default). When Zen ships a new model, add its entry here
/// after checking models.dev; a stale entry degrades to a now-legible 400
/// naming the rejected level.

///|
/// One model's reasoning surface: the selectable effort levels (empty for a
/// plain on/off toggle) and whether thinking can be switched off ("off" in
/// the picker).
priv struct ZenEffortPreset {
  levels : Array[String]
  can_disable : Bool
}

///|
/// The preset table, keyed by Zen's bare model id.
let zen_effort_presets : Array[(String, ZenEffortPreset)] = [
  // deepseek
  ("deepseek-v4-flash", { levels: ["low", "high", "max"], can_disable: true }),
  ("deepseek-v4-pro", { levels: ["high", "max"], can_disable: true }),
  // zen free preview
  ("x-preview-f-free", { levels: ["low", "high", "max"], can_disable: false }),
  // claude
  (
    "claude-fable-5",
    { levels: ["low", "medium", "high", "xhigh", "max"], can_disable: false },
  ),
  ("claude-opus-4-5", { levels: ["low", "medium", "high"], can_disable: false }),
  (
    "claude-opus-4-6",
    { levels: ["low", "medium", "high", "max"], can_disable: false },
  ),
  (
    "claude-opus-4-7",
    { levels: ["low", "medium", "high", "xhigh", "max"], can_disable: false },
  ),
  (
    "claude-opus-4-8",
    { levels: ["low", "medium", "high", "xhigh", "max"], can_disable: false },
  ),
  (
    "claude-opus-5",
    { levels: ["low", "medium", "high", "xhigh", "max"], can_disable: false },
  ),
  (
    "claude-sonnet-4-6",
    { levels: ["low", "medium", "high", "max"], can_disable: false },
  ),
  (
    "claude-sonnet-5",
    { levels: ["low", "medium", "high", "xhigh", "max"], can_disable: false },
  ),
  // gpt
  (
    "gpt-5",
    { levels: ["minimal", "low", "medium", "high"], can_disable: false },
  ),
  (
    "gpt-5-nano",
    { levels: ["minimal", "low", "medium", "high"], can_disable: false },
  ),
  ("gpt-5-codex", { levels: ["low", "medium", "high"], can_disable: false }),
  ("gpt-5.1", { levels: ["low", "medium", "high"], can_disable: true }),
  ("gpt-5.1-codex", { levels: ["low", "medium", "high"], can_disable: false }),
  (
    "gpt-5.1-codex-max",
    { levels: ["low", "medium", "high", "xhigh"], can_disable: false },
  ),
  (
    "gpt-5.1-codex-mini",
    { levels: ["low", "medium", "high"], can_disable: false },
  ),
  ("gpt-5.2", { levels: ["low", "medium", "high", "xhigh"], can_disable: true }),
  (
    "gpt-5.2-codex",
    { levels: ["low", "medium", "high", "xhigh"], can_disable: false },
  ),
  (
    "gpt-5.3-codex",
    { levels: ["low", "medium", "high", "xhigh"], can_disable: true },
  ),
  (
    "gpt-5.3-codex-spark",
    { levels: ["low", "medium", "high", "xhigh"], can_disable: false },
  ),
  ("gpt-5.4", { levels: ["low", "medium", "high", "xhigh"], can_disable: true }),
  (
    "gpt-5.4-mini",
    { levels: ["low", "medium", "high", "xhigh"], can_disable: true },
  ),
  (
    "gpt-5.4-nano",
    { levels: ["low", "medium", "high", "xhigh"], can_disable: true },
  ),
  ("gpt-5.4-pro", { levels: ["medium", "high", "xhigh"], can_disable: false }),
  ("gpt-5.5", { levels: ["low", "medium", "high", "xhigh"], can_disable: true }),
  ("gpt-5.5-pro", { levels: ["medium", "high", "xhigh"], can_disable: false }),
  (
    "gpt-5.6-luna",
    { levels: ["low", "medium", "high", "xhigh", "max"], can_disable: true },
  ),
  (
    "gpt-5.6-sol",
    { levels: ["low", "medium", "high", "xhigh", "max"], can_disable: true },
  ),
  (
    "gpt-5.6-terra",
    { levels: ["low", "medium", "high", "xhigh", "max"], can_disable: true },
  ),
  // gemini
  (
    "gemini-3-flash",
    { levels: ["minimal", "low", "medium", "high"], can_disable: false },
  ),
  ("gemini-3.1-pro", { levels: ["low", "medium", "high"], can_disable: false }),
  (
    "gemini-3.5-flash",
    { levels: ["minimal", "low", "medium", "high"], can_disable: false },
  ),
  (
    "gemini-3.5-flash-lite",
    { levels: ["minimal", "low", "medium", "high"], can_disable: false },
  ),
  (
    "gemini-3.6-flash",
    { levels: ["minimal", "low", "medium", "high"], can_disable: false },
  ),
  (
    "gemini-3.7-flash",
    { levels: ["low", "medium", "high"], can_disable: false },
  ),
  // kimi
  ("kimi-k2.5", { levels: [], can_disable: true }),
  ("kimi-k2.6", { levels: [], can_disable: true }),
  ("kimi-k3", { levels: ["max"], can_disable: false }),
  // qwen
  ("qwen3.5-plus", { levels: [], can_disable: true }),
  ("qwen3.6-plus", { levels: [], can_disable: true }),
  // glm
  ("glm-5", { levels: [], can_disable: true }),
  ("glm-5.1", { levels: [], can_disable: true }),
  ("glm-5.2", { levels: ["high", "max"], can_disable: false }),
]

///|
/// Look up the reasoning preset for one bare Zen model id.
fn zen_effort_preset(model_id : String) -> ZenEffortPreset? {
  for entry in zen_effort_presets {
    if entry.0 == model_id {
      return Some(entry.1)
    }
  }
  None
}

///|
/// The effort a level-bearing preset starts on: "high" when the model offers
/// it, otherwise the first declared level (e.g. "max" for kimi-k3).
fn zen_preset_default_level(levels : Array[String]) -> String {
  if levels.contains("high") {
    "high"
  } else {
    levels[0]
  }
}
