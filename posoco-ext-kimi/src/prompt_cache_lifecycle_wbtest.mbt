///|
test "prompt-cache rejection survives a rebuilt Kimi port" {
  let state : Ref[Bool] = Ref(false)
  let base = KimiConfig("key", send_prompt_cache_key=true)
  let first = kimi_model_port_with_prompt_cache_rejection_state(
    base,
    @devkit.ExtContext::default(),
    state,
  )
  assert_eq(first.prompt_cache_key_for("session-1"), Some("posoco-session-1"))

  first.learn_prompt_cache_key_rejection(
    "{\"error\":{\"message\":\"Unsupported parameter: prompt_cache_key\"}}",
  )
  assert_true(state.val)
  assert_eq(first.prompt_cache_key_for("session-1"), None)

  let rebuilt_config = base.with_reasoning_effort("low") catch {
    err => abort("fixture effort must be valid: " + err.to_string())
  }
  let rebuilt = kimi_model_port_with_prompt_cache_rejection_state(
    rebuilt_config,
    @devkit.ExtContext::default(),
    state,
  )
  assert_eq(rebuilt.prompt_cache_key_for("session-1"), None)
}

///|
test "unrelated Kimi ports keep independent prompt-cache rejection state" {
  let first_state : Ref[Bool] = Ref(false)
  let second_state : Ref[Bool] = Ref(false)
  let config = KimiConfig("key", send_prompt_cache_key=true)
  let first = kimi_model_port_with_prompt_cache_rejection_state(
    config,
    @devkit.ExtContext::default(),
    first_state,
  )
  let second = kimi_model_port_with_prompt_cache_rejection_state(
    config,
    @devkit.ExtContext::default(),
    second_state,
  )

  first.learn_prompt_cache_key_rejection(
    "Unsupported parameter: prompt_cache_key",
  )
  assert_eq(first.prompt_cache_key_for("session-1"), None)
  assert_eq(second.prompt_cache_key_for("session-1"), Some("posoco-session-1"))
}
