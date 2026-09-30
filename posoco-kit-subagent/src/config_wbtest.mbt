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
fn sample_config() -> SubagentConfig {
  SubagentConfig::{
    default_model: Some("zai/glm-5.3"),
    default_effort: Some("medium"),
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
  assert_eq(config.default_model, None)
  assert_eq(config.default_effort, None)
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
    parse_subagent_config("{\"limits\": {}}"),
    SubagentConfig::defaults(),
  )
}

///|
test "parse_full_config" {
  let text =
    #|{"default_model": "zai/glm-5.3",
    #|"default_effort": "medium",
    #|"limits": {"swarm_items": 8, "concurrency": 2, "global_concurrency": 10, "timeout_ms": 60000, "spawn_budget": 32}}
  assert_eq(parse_subagent_config(text), sample_config())
}

///|
test "parse_omitted_fields_default" {
  let config = parse_subagent_config("{}")
  assert_eq(config.default_model, None)
  assert_eq(config.default_effort, None)
  assert_eq(config.limits, SubagentConfig::defaults().limits)
}

///|
test "parse_ignores_unknown_keys" {
  assert_eq(
    parse_subagent_config(
      "{\"unknown\": 1, \"kinds\": [], \"extra\": {\"nested\": true}}",
    ),
    SubagentConfig::defaults(),
  )
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
test "parse_rejects_bad_default_model" {
  assert_true(config_error("{\"default_model\": 4}").contains("default_model"))
  assert_true(
    config_error("{\"default_model\": \"\"}").contains("default_model"),
  )
}

///|
test "parse_rejects_bad_default_effort" {
  assert_true(
    config_error("{\"default_effort\": 2}").contains("default_effort"),
  )
  assert_true(
    config_error("{\"default_effort\": \"\"}").contains("default_effort"),
  )
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
