///|
/// Parse expecting failure; returns the rejection reason.
fn config_error(text : String) -> String raise {
  let outcome : Result[SubagentConfig, SubagentConfigError] = Ok(
    parse_subagent_config(text),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(SubagentConfigError::Malformed(reason)) => reason
    Err(SubagentConfigError::Invalid(reason)) => reason
    _ => fail("expected the config to be rejected")
  }
}

///|
/// Resolve expecting failure; returns the rejection reason.
fn resolve_error(
  config : SubagentConfig,
  model? : String? = None,
  effort? : String? = None,
  parent_slot? : String = "parent/slot",
  parent_effort? : String? = None,
) -> String raise {
  let outcome : Result[ResolvedSelection, SubagentConfigError] = Ok(
    config.resolve(model~, effort~, parent_slot~, parent_effort~),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(SubagentConfigError::Malformed(reason)) => reason
    Err(SubagentConfigError::Invalid(reason)) => reason
    _ => fail("expected the resolve to be rejected")
  }
}

///|
fn sample_config() -> SubagentConfig {
  SubagentConfig::{
    models: [
      ConfigModel::{
        slot: "zai/glm-5.3",
        efforts: ["low", "medium", "high"],
        default_effort: Some("medium"),
      },
      ConfigModel::{
        slot: "openrouter/claude-sonnet-5",
        efforts: [],
        default_effort: None,
      },
    ],
    default_slot: Some("zai/glm-5.3"),
    limits: {
      swarm_items: 8,
      concurrency: 2,
      global_concurrency: 10,
      timeout_ms: 60000,
      spawn_budget: 32,
    },
  }
}

// ──────────────────────────────────────────────────────────────────────────
// defaults + parse
// ──────────────────────────────────────────────────────────────────────────

///|
test "defaults_match_design_9_2_numbers" {
  let config = SubagentConfig::defaults()
  assert_eq(config.models, [])
  assert_eq(config.default_slot, None)
  assert_eq(config.limits.swarm_items, 16)
  assert_eq(config.limits.concurrency, 4)
  assert_eq(config.limits.global_concurrency, 20)
  assert_eq(config.limits.timeout_ms, 1800000)
  assert_eq(config.limits.spawn_budget, 64)
}

///|
test "parse_empty_object_gives_defaults" {
  assert_eq(parse_subagent_config("{}"), SubagentConfig::defaults())
  assert_eq(
    parse_subagent_config("{\"models\": [], \"limits\": {}}"),
    SubagentConfig::defaults(),
  )
}

///|
test "parse_full_config" {
  let text =
    #|{"models": [
    #|  {"slot": "zai/glm-5.3", "efforts": ["low", "medium", "high"], "default_effort": "medium"},
    #|  {"slot": "openrouter/claude-sonnet-5", "efforts": []}
    #|],
    #|"default_slot": "zai/glm-5.3",
    #|"limits": {"swarm_items": 8, "concurrency": 2, "global_concurrency": 10, "timeout_ms": 60000, "spawn_budget": 32}}
  let config = parse_subagent_config(text)
  assert_eq(config, sample_config())
}

///|
test "parse_omitted_model_fields_default" {
  let config = parse_subagent_config("{\"models\": [{\"slot\": \"s\"}]}")
  assert_eq(config.models.length(), 1)
  assert_eq(config.models[0].efforts, [])
  assert_eq(config.models[0].default_effort, None)
  assert_eq(config.default_slot, None)
  assert_eq(config.limits, SubagentConfig::defaults().limits)
}

///|
test "parse_partial_limits_fill_defaults_per_field" {
  let config = parse_subagent_config("{\"limits\": {\"concurrency\": 8}}")
  assert_eq(config.limits.concurrency, 8)
  assert_eq(config.limits.swarm_items, 16)
  assert_eq(config.limits.global_concurrency, 20)
  assert_eq(config.limits.timeout_ms, 1800000)
  assert_eq(config.limits.spawn_budget, 64)
}

///|
test "parse_ignores_unknown_keys" {
  let config = parse_subagent_config(
    "{\"unknown\": 1, \"models\": [], \"extra\": {\"nested\": true}}",
  )
  assert_eq(config, SubagentConfig::defaults())
}

///|
test "parse_rejects_malformed_json" {
  let reason = config_error("{not json")
  assert_true(reason.contains("not valid JSON"))
}

///|
test "parse_rejects_non_object_root" {
  assert_true(config_error("[]").contains("object"))
  assert_true(config_error("\"str\"").contains("object"))
}

///|
test "parse_rejects_models_not_array" {
  assert_true(config_error("{\"models\": {}}").contains("models"))
}

///|
test "parse_rejects_model_entry_not_object" {
  assert_true(config_error("{\"models\": [3]}").contains("objects"))
}

///|
test "parse_rejects_slot_wrong_type" {
  assert_true(config_error("{\"models\": [{\"slot\": 3}]}").contains("slot"))
  assert_true(config_error("{\"models\": [{}]}").contains("slot"))
}

///|
test "parse_rejects_empty_slot" {
  let reason = config_error("{\"models\": [{\"slot\": \"\"}]}")
  assert_true(reason.contains("slot"))
  assert_true(reason.contains("non-empty"))
}

///|
test "parse_rejects_duplicate_slot" {
  let reason = config_error(
    "{\"models\": [{\"slot\": \"a/b\"}, {\"slot\": \"a/b\"}]}",
  )
  assert_true(reason.contains("duplicate"))
  assert_true(reason.contains("a/b"))
}

///|
test "parse_rejects_bad_efforts" {
  assert_true(
    config_error("{\"models\": [{\"slot\": \"s\", \"efforts\": \"low\"}]}").contains(
      "efforts",
    ),
  )
  assert_true(
    config_error("{\"models\": [{\"slot\": \"s\", \"efforts\": [3]}]}").contains(
      "efforts",
    ),
  )
  assert_true(
    config_error("{\"models\": [{\"slot\": \"s\", \"efforts\": [\"\"]}]}").contains(
      "efforts",
    ),
  )
}

///|
test "parse_rejects_bad_default_effort" {
  assert_true(
    config_error("{\"models\": [{\"slot\": \"s\", \"default_effort\": 2}]}").contains(
      "default_effort",
    ),
  )
  assert_true(
    config_error("{\"models\": [{\"slot\": \"s\", \"default_effort\": \"\"}]}").contains(
      "default_effort",
    ),
  )
}

///|
test "parse_rejects_bad_default_slot" {
  assert_true(config_error("{\"default_slot\": 4}").contains("default_slot"))
  assert_true(config_error("{\"default_slot\": \"\"}").contains("default_slot"))
}

///|
test "parse_rejects_bad_limits" {
  assert_true(config_error("{\"limits\": []}").contains("limits"))
  assert_true(
    config_error("{\"limits\": {\"concurrency\": \"four\"}}").contains(
      "concurrency",
    ),
  )
  assert_true(
    config_error("{\"limits\": {\"timeout_ms\": 1.5}}").contains("timeout_ms"),
  )
}

// ──────────────────────────────────────────────────────────────────────────
// resolve
// ──────────────────────────────────────────────────────────────────────────

///|
test "resolve_empty_models_explicit_values_pass_through_unvalidated" {
  let resolved = SubagentConfig::defaults().resolve(
    model=Some("not/in/config"),
    effort=Some("ultra"),
    parent_slot="parent/slot",
    parent_effort=Some("medium"),
  )
  assert_eq(resolved, ResolvedSelection::{
    slot: "not/in/config",
    effort: Some("ultra"),
  })
}

///|
test "resolve_empty_models_inherits_parent_selection" {
  let resolved = SubagentConfig::defaults().resolve(
    parent_slot="parent/slot",
    parent_effort=Some("medium"),
  )
  assert_eq(resolved, ResolvedSelection::{
    slot: "parent/slot",
    effort: Some("medium"),
  })
  // Parent without an effort echoes None.
  let no_effort = SubagentConfig::defaults().resolve(parent_slot="parent/slot")
  assert_eq(no_effort, ResolvedSelection::{ slot: "parent/slot", effort: None, })
}

///|
test "resolve_explicit_model_and_effort_accepted" {
  let resolved = sample_config().resolve(
    model=Some("zai/glm-5.3"),
    effort=Some("high"),
    parent_slot="parent/slot",
  )
  assert_eq(resolved, ResolvedSelection::{
    slot: "zai/glm-5.3",
    effort: Some("high"),
  })
}

///|
test "resolve_unknown_model_error_lists_allowed_slots" {
  let reason = resolve_error(
    sample_config(),
    model=Some("anthropic/opus"),
    parent_slot="parent/slot",
  )
  assert_true(reason.contains("anthropic/opus"))
  assert_true(reason.contains("allowed slots"))
  assert_true(reason.contains("zai/glm-5.3"))
  assert_true(reason.contains("openrouter/claude-sonnet-5"))
}

///|
test "resolve_unknown_effort_error_lists_entry_efforts" {
  let reason = resolve_error(
    sample_config(),
    model=Some("zai/glm-5.3"),
    effort=Some("ultra"),
    parent_slot="parent/slot",
  )
  assert_true(reason.contains("ultra"))
  assert_true(reason.contains("zai/glm-5.3"))
  assert_true(reason.contains("low"))
  assert_true(reason.contains("medium"))
  assert_true(reason.contains("high"))
}

///|
test "resolve_empty_efforts_accept_any_effort" {
  let resolved = sample_config().resolve(
    model=Some("openrouter/claude-sonnet-5"),
    effort=Some("whatever"),
    parent_slot="parent/slot",
  )
  assert_eq(resolved, ResolvedSelection::{
    slot: "openrouter/claude-sonnet-5",
    effort: Some("whatever"),
  })
}

///|
test "resolve_model_without_effort_uses_entry_default_effort" {
  let resolved = sample_config().resolve(
    model=Some("zai/glm-5.3"),
    parent_slot="parent/slot",
  )
  assert_eq(resolved, ResolvedSelection::{
    slot: "zai/glm-5.3",
    effort: Some("medium"),
  })
  // Entry without default_effort yields effort None.
  let none_effort = sample_config().resolve(
    model=Some("openrouter/claude-sonnet-5"),
    parent_slot="parent/slot",
  )
  assert_eq(none_effort, ResolvedSelection::{
    slot: "openrouter/claude-sonnet-5",
    effort: None,
  })
}

///|
test "resolve_no_model_falls_back_to_default_slot" {
  let resolved = sample_config().resolve(parent_slot="parent/slot")
  assert_eq(resolved, ResolvedSelection::{
    slot: "zai/glm-5.3",
    effort: Some("medium"),
  })
  // Explicit effort with no model validates against the default entry.
  assert_eq(
    sample_config().resolve(effort=Some("low"), parent_slot="parent/slot"),
    ResolvedSelection::{ slot: "zai/glm-5.3", effort: Some("low"), },
  )
  let reason = resolve_error(
    sample_config(),
    effort=Some("ultra"),
    parent_slot="parent/slot",
  )
  assert_true(reason.contains("ultra"))
  assert_true(reason.contains("low"))
}

///|
test "resolve_no_model_without_default_slot_errors_and_lists_slots" {
  let config = SubagentConfig::{
    models: [
      ConfigModel::{ slot: "a", efforts: [], default_effort: None, },
      ConfigModel::{ slot: "b", efforts: [], default_effort: None, },
    ],
    default_slot: None,
    limits: SubagentConfig::defaults().limits,
  }
  let reason = resolve_error(config, parent_slot="parent/slot")
  assert_true(reason.contains("default_slot"))
  assert_true(reason.contains("allowed slots"))
  assert_true(reason.contains("a"))
  assert_true(reason.contains("b"))
}

///|
test "resolve_default_slot_not_among_models_errors" {
  let config = SubagentConfig::{
    models: [ConfigModel::{ slot: "a", efforts: [], default_effort: None, }],
    default_slot: Some("ghost"),
    limits: SubagentConfig::defaults().limits,
  }
  let reason = resolve_error(config, parent_slot="parent/slot")
  assert_true(reason.contains("ghost"))
  assert_true(reason.contains("allowed slots"))
}

///|
test "resolve_parent_values_ignored_when_models_configured" {
  let resolved = sample_config().resolve(
    parent_slot="parent/slot",
    parent_effort=Some("high"),
  )
  // Default slot wins; the parent effort is NOT echoed (default_effort used).
  assert_eq(resolved, ResolvedSelection::{
    slot: "zai/glm-5.3",
    effort: Some("medium"),
  })
}
