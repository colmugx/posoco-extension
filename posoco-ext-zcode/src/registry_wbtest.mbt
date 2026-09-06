///|
/// v2-shaped configs are synthetic; every apiKey below is a fake
/// ("sk-test-…"). Assertions only touch the union shape (source == "inline")
/// and the value length — never a key value, per registry.mbt's security note.

///|
fn registry_v2_of(text : String) -> Json raise {
  @json.parse(text) catch {
    err => fail(err.to_string())
  }
}

///|
fn registry_providers(payload : Json) -> Array[Json] {
  match json_field(payload, "providers") {
    Some(Json::Array(elements)) => elements
    _ => []
  }
}

///|
fn registry_element_of(providers : Array[Json], id : String) -> Json? {
  for element in providers {
    if json_field_string(element, "providerId") == Some(id) {
      return Some(element)
    }
  }
  None
}

///|
test "registry_inline_api_key_becomes_union_shape" {
  let raw =
    #|{"provider": {"prov-a": {"kind": "anthropic", "name": "Prov A", "models": {"glm-4.6": {}}, "options": {"baseURL": "https://api.example.com/v1", "apiKey": "sk-test-0000000000000000", "apiKeyRequired": true}}}}
  match zcode_build_registry(registry_v2_of(raw), generated_at_ms=1788536787L) {
    Ok(payload) => {
      let providers = registry_providers(payload)
      assert_eq(providers.length(), 1)
      match json_field(providers[0], "apiKey") {
        Some(Json::Object(api_key)) => {
          let source = api_key.get("source")
          assert_true(source == Some(Json::string("inline")))
          match api_key.get("value") {
            Some(Json::String(value)) =>
              assert_eq(value.length(), "sk-test-0000000000000000".length())
            _ => fail("expected an apiKey value string")
          }
        }
        _ => fail("expected an inline apiKey object")
      }
      let required = json_field(providers[0], "apiKeyRequired")
      assert_true(required == Some(Json::boolean(true)))
    }
    Err(message) => fail(message)
  }
}

///|
test "registry_models_serialized_as_array_sorted" {
  let raw =
    #|{"provider": {"prov-a": {"kind": "anthropic", "models": {"glm-4.6": {"name": "GLM-4.6", "limit": {"context": 200000, "output": 32000}}, "glm-4.5-air": {"name": "GLM-4.5-Air"}}, "options": {"apiKey": "sk-test-0000000000000001"}}}}
  match zcode_build_registry(registry_v2_of(raw), generated_at_ms=1788536787L) {
    Ok(payload) => {
      let element = registry_providers(payload)[0]
      let models = match json_field(element, "models") {
        Some(Json::Array(models)) => models
        _ => fail("expected models to be a JSON array")
      }
      assert_eq(models.length(), 2)
      // v2 config stores a map; output must be sorted for a stable revision.
      // NOTE: this toolchain orders Strings by length first, then content —
      // "glm-4.6" (7 chars) sorts before "glm-4.5-air" (11 chars).
      assert_eq(json_field_string(models[0], "modelId").unwrap(), "glm-4.6")
      assert_eq(json_field_string(models[1], "modelId").unwrap(), "glm-4.5-air")
      assert_eq(json_field_int(models[0], "contextWindow"), 200000)
      assert_eq(json_field_int(models[0], "maxOutputTokens"), 32000)
    }
    Err(message) => fail(message)
  }
}

///|
test "registry_zero_model_provider_skipped" {
  let raw =
    #|{"provider": {"live": {"kind": "anthropic", "models": {"glm-4.6": {}}, "options": {"apiKey": "sk-test-0000000000000002"}}, "empty-models": {"kind": "openai", "models": {}, "options": {"apiKey": "sk-test-0000000000000003"}}, "missing-models": {"kind": "openai", "options": {"apiKey": "sk-test-0000000000000004"}}}}
  match zcode_build_registry(registry_v2_of(raw), generated_at_ms=1788536787L) {
    Ok(payload) => {
      let providers = registry_providers(payload)
      assert_eq(providers.length(), 1)
      assert_eq(json_field_string(providers[0], "providerId").unwrap(), "live")
    }
    Err(message) => fail(message)
  }
}

///|
test "registry_keyless_provider_skipped" {
  // Proven live against zcode 3.11: the app-server defaults to the first
  // provider entry and a provider without an inline api key cannot serve a
  // turn, so keyless entries are dropped instead of poisoning that pick.
  let raw =
    #|{"provider": {"live": {"kind": "anthropic", "models": {"glm-4.6": {}}, "options": {"apiKey": "sk-test-0000000000000005"}}, "empty-key": {"kind": "anthropic", "models": {"m": {}}, "options": {"apiKey": ""}}, "missing-key": {"kind": "anthropic", "models": {"m": {}}}}}
  match zcode_build_registry(registry_v2_of(raw), generated_at_ms=1788536787L) {
    Ok(payload) => {
      let providers = registry_providers(payload)
      assert_eq(providers.length(), 1)
      assert_eq(json_field_string(providers[0], "providerId").unwrap(), "live")
    }
    Err(message) => fail(message)
  }
}

///|
test "registry_providers_ordered_lexicographically" {
  // The app-server defaults to the first provider entry, so the element
  // order is meaningful; this core's default String compare is length-first
  // ("zz" would win), but the payload must use code-unit order.
  let raw =
    #|{"provider": {"zz": {"kind": "anthropic", "models": {"m": {}}, "options": {"apiKey": "sk-test-000000000000000c"}}, "aaaa": {"kind": "anthropic", "models": {"m": {}}, "options": {"apiKey": "sk-test-000000000000000d"}}}}
  match zcode_build_registry(registry_v2_of(raw), generated_at_ms=1788536787L) {
    Ok(payload) => {
      let providers = registry_providers(payload)
      assert_eq(json_field_string(providers[0], "providerId").unwrap(), "aaaa")
      assert_eq(json_field_string(providers[1], "providerId").unwrap(), "zz")
    }
    Err(message) => fail(message)
  }
}

///|
test "registry_api_format_mapping" {
  let raw =
    #|{"provider": {"pa": {"kind": "anthropic", "models": {"m1": {}}, "options": {"apiKey": "sk-test-0000000000000006"}}, "po": {"kind": "openai-compatible", "models": {"m1": {}}, "options": {"apiKey": "sk-test-0000000000000007"}}, "px": {"kind": "vertex-express", "models": {"m1": {}}, "options": {"apiKey": "sk-test-0000000000000008"}}}}
  match zcode_build_registry(registry_v2_of(raw), generated_at_ms=1788536787L) {
    Ok(payload) => {
      let providers = registry_providers(payload)
      let pa = registry_element_of(providers, "pa").unwrap()
      let po = registry_element_of(providers, "po").unwrap()
      let px = registry_element_of(providers, "px").unwrap()
      let pa_format = json_field(pa, "apiFormat")
      assert_true(pa_format == Some(Json::string("anthropic-messages")))
      let po_format = json_field(po, "apiFormat")
      assert_true(po_format == Some(Json::string("openai-chat-completions")))
      assert_true(json_field(px, "apiFormat") is None)
    }
    Err(message) => fail(message)
  }
}

///|
test "registry_revision_stable_and_hex_shaped" {
  let raw =
    #|{"provider": {"prov-a": {"kind": "anthropic", "models": {"glm-4.6": {}}, "options": {"apiKey": "sk-test-0000000000000009"}}}}
  let v2 = registry_v2_of(raw)
  match
    (
      zcode_build_registry(v2, generated_at_ms=1788536787L),
      zcode_build_registry(v2, generated_at_ms=1788536787L),
    ) {
    (Ok(first), Ok(second)) => {
      assert_true(first == second)
      let revision = json_field_string(first, "revision").unwrap()
      assert_eq(revision.length(), 8)
    }
    (Err(message), _) => fail(message)
    (_, Err(message)) => fail(message)
  }
}

///|
test "registry_revision_changes_when_provider_added" {
  let small_raw =
    #|{"provider": {"prov-a": {"kind": "anthropic", "models": {"glm-4.6": {}}, "options": {"apiKey": "sk-test-000000000000000a"}}}}
  let grown_raw =
    #|{"provider": {"prov-a": {"kind": "anthropic", "models": {"glm-4.6": {}}, "options": {"apiKey": "sk-test-000000000000000a"}}, "prov-b": {"kind": "openai", "models": {"gpt-test": {}}, "options": {"apiKey": "sk-test-000000000000000b"}}}}
  match
    (
      zcode_build_registry(
        registry_v2_of(small_raw),
        generated_at_ms=1788536787L,
      ),
      zcode_build_registry(
        registry_v2_of(grown_raw),
        generated_at_ms=1788536787L,
      ),
    ) {
    (Ok(small), Ok(grown)) => {
      let small_rev = json_field_string(small, "revision").unwrap()
      let grown_rev = json_field_string(grown, "revision").unwrap()
      assert_true(small_rev != grown_rev)
    }
    (Err(message), _) => fail(message)
    (_, Err(message)) => fail(message)
  }
}

///|
test "registry_provider_map_shapes" {
  // An empty provider map is a valid (empty) registry; a missing or
  // non-object provider map is an error.
  let empty =
    #|{"provider": {}}
  match zcode_build_registry(registry_v2_of(empty), generated_at_ms=0L) {
    Ok(payload) => assert_eq(registry_providers(payload).length(), 0)
    Err(message) => fail(message)
  }
  let missing =
    #|{"kind": "anthropic"}
  match zcode_build_registry(registry_v2_of(missing), generated_at_ms=0L) {
    Ok(_) => fail("expected an error for missing provider map")
    Err(_) => ()
  }
}
