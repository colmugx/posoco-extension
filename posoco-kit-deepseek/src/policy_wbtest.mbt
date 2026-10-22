///|
/// The shared settings parser: one key vocabulary, two provider planes.

///|
test "absent settings inherit the conservative protections" {
  let policy = DeepSeekPolicy::from_settings(None, manifest_id="kit")
  assert_eq(policy, DeepSeekPolicy::default_protections())
  assert_eq(policy.max_reasoning_chars, Some(120000))
  assert_eq(policy.repeated_reasoning_span_chars, Some(256))
  assert_true(policy.recover_on_reasoning_exhaustion)
}

///|
test "explicit null and false opt out of every guard" {
  let policy = DeepSeekPolicy::from_settings(
    Some(
      Json::object({
        "max_reasoning_chars": Json::null(),
        "repeated_reasoning_span_chars": Json::null(),
        "recover_on_reasoning_exhaustion": Json::boolean(false),
      }),
    ),
    manifest_id="kit",
  )
  assert_eq(policy, DeepSeekPolicy::disabled())
}

///|
test "explicit values override the defaults" {
  let policy = DeepSeekPolicy::from_settings(
    Some(
      Json::object({
        "max_reasoning_chars": Json::number(5000.0),
        "repeated_reasoning_span_chars": Json::number(128.0),
        "recover_on_reasoning_exhaustion": Json::boolean(true),
      }),
    ),
    manifest_id="kit",
  )
  assert_eq(policy.max_reasoning_chars, Some(5000))
  assert_eq(policy.repeated_reasoning_span_chars, Some(128))
  assert_true(policy.recover_on_reasoning_exhaustion)
}

///|
test "caller defaults replace the built-in protections" {
  let disabled = DeepSeekPolicy::disabled()
  let policy = DeepSeekPolicy::from_settings(
    Some(Json::object({ "api_key": Json::string("k") })),
    manifest_id="kit",
    defaults=disabled,
  )
  assert_eq(policy, disabled)
}

///|
test "malformed settings are typed composition failures" {
  let rejects = fn(settings : Json) -> Bool {
    try DeepSeekPolicy::from_settings(Some(settings), manifest_id="kit") catch {
      @posoco.CompositionError::ManifestSchemaError(manifest_id~, ..) =>
        manifest_id == "kit"
      _ => false
    } noraise {
      _ => false
    }
  }
  // A non-object source cannot describe a policy.
  assert_true(rejects(Json::array([])))
  // Non-integer / non-positive / out-of-range ceilings.
  assert_true(
    rejects(Json::object({ "max_reasoning_chars": Json::string("1") })),
  )
  assert_true(
    rejects(Json::object({ "max_reasoning_chars": Json::number(0.0) })),
  )
  assert_true(
    rejects(Json::object({ "max_reasoning_chars": Json::number(1.5) })),
  )
  // The collapse span has a hard floor and ceiling.
  assert_true(
    rejects(
      Json::object({ "repeated_reasoning_span_chars": Json::number(32.0) }),
    ),
  )
  assert_true(
    rejects(
      Json::object({
        "repeated_reasoning_span_chars": Json::number(715827883.0),
      }),
    ),
  )
  // Recovery is a boolean, never a truthy string.
  assert_true(
    rejects(
      Json::object({ "recover_on_reasoning_exhaustion": Json::string("yes") }),
    ),
  )
  // Valid shapes still parse.
  assert_false(
    rejects(Json::object({ "max_reasoning_chars": Json::number(1.0) })),
  )
}
