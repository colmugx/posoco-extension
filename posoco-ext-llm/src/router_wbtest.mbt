///|
/// Router tests use an injected port so they do not require a provider
/// adapter, network access, or endpoint configuration.
struct RouterTestPort {
  reasoning_effort_values : Array[String]
}

///|
pub impl @posoco.ModelPort for RouterTestPort with fn chat(
  _self : RouterTestPort,
  _scope : @posoco.InvocationScope,
  _messages : Array[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport(
    "router test port was not expected to chat",
  )
}

///|
pub impl @posoco.ModelPort for RouterTestPort with fn compact(
  _self : RouterTestPort,
  _scope : @posoco.InvocationScope,
  _messages : Array[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "router test port does not implement compact",
  )
}

///|
pub impl @posoco.ModelPort for RouterTestPort with fn provider_config(
  self : RouterTestPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::ProviderConfig(
    reasoning_effort_values=self.reasoning_effort_values,
  )
}

///|
fn router_test_slot(
  id : String,
  provider_id : String,
  model_id : String,
  reasoning_effort_values : Array[String],
) -> ModelSlot {
  let port : &@posoco.ModelPort = RouterTestPort::{ reasoning_effort_values, }
  ModelSlot::ModelSlot(id~, label=id, provider_id~, model_id~, port~)
}

///|
/// A slot advertising reasoning efforts with a working rebuild hook, so
/// `select_effort` can be exercised without a provider adapter.
fn router_effort_slot(
  id : String,
  provider_id : String,
  model_id : String,
) -> ModelSlot {
  let base = router_test_slot(id, provider_id, model_id, ["low", "high"])
  {
    ..base,
    thinking_efforts: ["low", "high"],
    default_effort: Some("low"),
    rebuild_on_effort: Some(_ => base),
  }
}

///|
test "router rejects an empty slot list" {
  let result = Ok(RouterModelPort::new(slots=[])) catch { error => Err(error) }
  match result {
    Err(@posoco.CompositionError::EmptyPort(name)) =>
      assert_eq(name, "posoco_ext_llm.slots")
    _ => fail("expected empty slot composition failure")
  }
}

///|
test "router rejects duplicate slot ids" {
  let first = router_test_slot("same", "one", "model-a", [])
  let second = router_test_slot("same", "two", "model-b", [])
  let result = Ok(RouterModelPort::new(slots=[first, second])) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      ignore(manifest_id)
      assert_true(detail.contains("duplicate model slot id: same"))
    }
    _ => fail("expected duplicate slot composition failure")
  }
}

///|
test "router selects the configured default and switches slots" {
  let first = router_test_slot("first", "one", "model-a", [])
  let second = router_test_slot("second", "two", "model-b", [])
  let router = RouterModelPort::new(
    slots=[first, second],
    default_slot_id="second",
  )
  assert_eq(router.active_slot_id(), "second")
  assert_eq(router.current_provider_id(), "two")
  assert_eq(router.current_model_id(), "model-b")
  router.switch_slot("first") catch {
    _ => fail("unexpected slot switch failure")
  }
  assert_eq(router.active_slot_id(), "first")
  assert_eq(router.list_slot_ids(), ["first", "second"])
}

///|
test "router delegates provider config to the active slot" {
  let first = router_test_slot("first", "one", "model-a", ["low", "high"])
  let second = router_test_slot("second", "two", "model-b", ["minimal"])
  let router = RouterModelPort::new(slots=[first, second])
  assert_eq(router.provider_config().reasoning_effort_values, ["low", "high"])
  router.switch_slot("second") catch {
    _ => fail("unexpected slot switch failure")
  }
  assert_eq(router.provider_config().reasoning_effort_values, ["minimal"])
}

///|
test "provider config rejects ambiguous legacy and tagged credentials" {
  let oauth = @oauth.Credential::Credential(
    access_token="access",
    refresh_token="refresh",
    expires_at=0,
  )
  let api = @oauth.ApiKeyCredential::ApiKeyCredential(secret="secret")
  let source = ProviderConfigSource::ProviderConfigSource(
    provider_credential=Some(@oauth.ProviderCredential::OAuth(oauth)),
    api_key_credential=Some(api),
  )
  let result = Ok(source.effective_credential("test-provider")) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~)) => {
      assert_eq(manifest_id, "posoco_ext_llm.credentials")
      assert_true(detail.contains("ambiguous credential"))
    }
    _ => fail("legacy/tagged credential coexistence must fail fast")
  }
}

///|
test "replace_provider_slots expands a provider in place and keeps order" {
  let outer = router_test_slot("outer", "other", "model-o", [])
  let single = router_test_slot("one/a", "one", "model-a", [])
  let router = RouterModelPort::new(
    slots=[outer, single],
    default_slot_id="one/a",
  )
  let replacements = [
    router_test_slot("one/a", "one", "model-a", []),
    router_test_slot("one/b", "one", "model-b", []),
    router_test_slot("one/c", "one", "model-c", []),
  ]
  router.replace_provider_slots("one", replacements) catch {
    _ => fail("unexpected replacement failure")
  }
  assert_eq(router.list_slot_ids(), ["outer", "one/a", "one/b", "one/c"])
  // The active slot id survived the object swap, so selection is preserved.
  assert_eq(router.active_slot_id(), "one/a")
}

///|
test "replace_provider_slots falls back when the active slot disappears" {
  let first = router_effort_slot("one/a", "one", "model-a")
  let second = router_test_slot("two/z", "two", "model-z", [])
  let router = RouterModelPort::new(slots=[first, second])
  router.select_effort("one/a", "high") catch {
    _ => fail("unexpected effort selection failure")
  }
  let replacements = [
    router_test_slot("one/x", "one", "model-x", []),
    router_test_slot("one/y", "one", "model-y", []),
  ]
  router.replace_provider_slots("one", replacements) catch {
    _ => fail("unexpected replacement failure")
  }
  // The old active id vanished; selection falls back to the provider's first
  // replacement slot and the effort selection is cleared.
  assert_eq(router.active_slot_id(), "one/x")
  assert_eq(router.active_effort(), None)
}

///|
test "replace_provider_slots rejects invalid replacements without mutation" {
  let single = router_test_slot("one/a", "one", "model-a", [])
  let router = RouterModelPort::new(slots=[single])
  let empty = Ok(router.replace_provider_slots("one", [])) catch {
    error => Err(error)
  }
  match empty {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("must not be empty"))
    _ => fail("an empty replacement list must fail fast")
  }
  let wrong_provider = [router_test_slot("two/b", "two", "model-b", [])]
  let mismatch = Ok(router.replace_provider_slots("one", wrong_provider)) catch {
    error => Err(error)
  }
  match mismatch {
    Err(@posoco.CompositionError::ManifestSchemaError(detail~, ..)) =>
      assert_true(detail.contains("provider id does not match"))
    _ => fail("a foreign-provider replacement must fail fast")
  }
  assert_eq(router.list_slot_ids(), ["one/a"])
  assert_eq(router.active_slot_id(), "one/a")
}

///|
test "replace_provider_slots appends when the provider contributed no slots" {
  let single = router_test_slot("one/a", "one", "model-a", [])
  let router = RouterModelPort::new(slots=[single])
  let replacements = [
    router_test_slot("three/a", "three", "model-a", []),
    router_test_slot("three/b", "three", "model-b", []),
  ]
  router.replace_provider_slots("three", replacements) catch {
    _ => fail("unexpected replacement failure")
  }
  assert_eq(router.list_slot_ids(), ["one/a", "three/a", "three/b"])
}
