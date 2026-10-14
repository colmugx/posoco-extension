///|
/// Canonical-contract tests: a ProviderFactory implemented against this kit,
/// catalog/slot construction and validation, config-source credential
/// resolution, and offline cached-window restoration — all without
/// posoco-ext-llm in the dependency graph.

///|
/// Inert port: slot composition requires a ModelPort, but these tests never
/// dispatch a call.
struct FakePort {}

///|
impl @posoco.ModelPort for FakePort with fn chat(
  _self : FakePort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport("fake port was not expected to chat")
}

///|
impl @posoco.ModelPort for FakePort with fn compact(
  _self : FakePort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "fake port does not implement compact",
  )
}

///|
impl @posoco.ModelPort for FakePort with fn provider_config(_self : FakePort) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
/// Deterministic factory: validates that a credential is present and emits a
/// one-slot catalog.
struct FakeFactory {
  id : String
}

///|
impl ProviderFactory for FakeFactory with fn provider_id(self : FakeFactory) -> String {
  self.id
}

///|
impl ProviderFactory for FakeFactory with fn credential_id(self : FakeFactory) -> String {
  self.id
}

///|
impl ProviderFactory for FakeFactory with fn build(
  self : FakeFactory,
  source : ProviderConfigSource,
) -> ProviderBuildResult raise @posoco.CompositionError {
  if source.effective_credential(self.id) is None {
    return ProviderBuildResult::Unconfigured
  }
  let port : &@posoco.ModelPort = FakePort::{ }
  ProviderBuildResult::Ready(
    ProviderModelCatalog::ProviderModelCatalog(provider_id=self.id, slots=[
      ModelSlot::ModelSlot(
        id="\{self.id}/m",
        label="m",
        provider_id=self.id,
        model_id="m",
        port~,
      ),
    ]),
  )
}

///|
fn fake_slot(id~ : String, provider_id~ : String) -> ModelSlot {
  let port : &@posoco.ModelPort = FakePort::{ }
  ModelSlot::ModelSlot(id~, label=id, provider_id~, model_id="model", port~)
}

///|
test "a ProviderFactory implementation builds a canonical catalog" {
  let factory : &ProviderFactory = FakeFactory::{ id: "fake", }
  let unconfigured = factory.build(ProviderConfigSource::ProviderConfigSource())
  match unconfigured {
    ProviderBuildResult::Unconfigured => ()
    ProviderBuildResult::Ready(_) =>
      fail("expected Unconfigured without a credential")
  }
  let configured = factory.build(
    ProviderConfigSource::ProviderConfigSource(
      provider_credential=Some(
        @oauth.ProviderCredential::OAuth(
          @oauth.Credential::Credential(
            access_token="access",
            refresh_token="refresh",
            expires_at=0,
          ),
        ),
      ),
    ),
  )
  match configured {
    ProviderBuildResult::Ready(catalog) => {
      assert_eq(catalog.provider_id(), "fake")
      assert_eq(catalog.slots().length(), 1)
      assert_eq(catalog.capabilities(), [])
      assert_eq(catalog.auth_methods(), [])
    }
    ProviderBuildResult::Unconfigured => fail("expected Ready")
  }
}

///|
test "catalog validation rejects malformed composition" {
  let invalid : Array[Array[ModelSlot]] = [
    [],
    [fake_slot(id="", provider_id="p")],
    [fake_slot(id="p/a", provider_id="other")],
    [fake_slot(id="p/a", provider_id="p"), fake_slot(id="p/a", provider_id="p")],
  ]
  for slots in invalid {
    let result = Ok(
      ProviderModelCatalog::ProviderModelCatalog(provider_id="p", slots~),
    ) catch {
      error => Err(error)
    }
    match result {
      Err(ManifestSchemaError(..)) | Err(EmptyPort(_)) => ()
      Err(other) => fail("unexpected error kind: \{other}")
      Ok(_) => fail("expected catalog validation failure")
    }
  }
  let empty_id = Ok(
    ProviderModelCatalog::ProviderModelCatalog(provider_id="", slots=[
      fake_slot(id="p/a", provider_id="p"),
    ]),
  ) catch {
    error => Err(error)
  }
  match empty_id {
    Err(ManifestSchemaError(..)) => ()
    Err(other) => fail("unexpected error kind: \{other}")
    Ok(_) => fail("expected empty provider id failure")
  }
}

///|
test "slot metadata and advertised auth methods are preserved" {
  let slot = {
    ..fake_slot(id="p/m", provider_id="p"),
    label: "Friendly",
    thinking_efforts: ["low", "high"],
    context_window: Some(128000),
    capabilities: ["chat", "tools"],
    default_effort: Some("low"),
    display_group: Some("Group"),
  }
  let catalog = ProviderModelCatalog::ProviderModelCatalog(
    provider_id="p",
    slots=[slot],
    capabilities=["chat"],
  )
  assert_eq(catalog.capabilities(), ["chat"])
  assert_eq(catalog.slots()[0].label, "Friendly")
  assert_eq(catalog.slots()[0].context_window, Some(128000))
  assert_eq(catalog.slots()[0].thinking_efforts, ["low", "high"])
  assert_eq(catalog.auth_methods(), [])
}

///|
fn sample_credential(access~ : String) -> @oauth.ProviderCredential {
  @oauth.ProviderCredential::OAuth(
    @oauth.Credential::Credential(
      access_token=access,
      refresh_token="refresh",
      expires_at=0,
    ),
  )
}

///|
test "config source resolves credentials and rejects ambiguous input" {
  // Canonical tag resolves as-is.
  let canonical = ProviderConfigSource::ProviderConfigSource(
    provider_credential=Some(sample_credential(access="access")),
  )
  let resolved = canonical.effective_credential("p") catch {
    _ => fail("unexpected credential failure")
  }
  match resolved {
    Some(@oauth.ProviderCredential::OAuth(_)) => ()
    _ => fail("expected canonical OAuth credential")
  }
  // Tagged + legacy is an observable composition failure.
  let ambiguous = ProviderConfigSource::ProviderConfigSource(
    provider_credential=Some(sample_credential(access="access")),
    credential=Some(
      @oauth.Credential::Credential(
        access_token="legacy",
        refresh_token="legacy",
        expires_at=0,
      ),
    ),
  )
  let result = Ok(ambiguous.effective_credential("p")) catch {
    error => Err(error)
  }
  match result {
    Err(ManifestSchemaError(..)) => ()
    Err(other) => fail("unexpected error kind: \{other}")
    Ok(_) => fail("expected ambiguous credential failure")
  }
  // Two legacy fields together fail the same way.
  let double_legacy = ProviderConfigSource::ProviderConfigSource(
    credential=Some(
      @oauth.Credential::Credential(
        access_token="a",
        refresh_token="r",
        expires_at=0,
      ),
    ),
    api_key_credential=Some(
      @oauth.ApiKeyCredential::ApiKeyCredential(secret="k"),
    ),
  )
  let legacy_result = Ok(double_legacy.effective_credential("p")) catch {
    error => Err(error)
  }
  match legacy_result {
    Err(ManifestSchemaError(..)) => ()
    Err(other) => fail("unexpected error kind: \{other}")
    Ok(_) => fail("expected ambiguous legacy credential failure")
  }
  // A single legacy field maps onto the canonical tags.
  let legacy_key = ProviderConfigSource::ProviderConfigSource(
    api_key_credential=Some(
      @oauth.ApiKeyCredential::ApiKeyCredential(secret="k"),
    ),
  )
  let key = legacy_key.effective_credential("p") catch {
    _ => fail("unexpected credential failure")
  }
  match key {
    Some(@oauth.ProviderCredential::ApiKey(_)) => ()
    _ => fail("expected canonical API-key credential")
  }
  // No credential at all is the unconfigured state.
  match ProviderConfigSource::ProviderConfigSource().effective_credential("p") {
    None => ()
    Some(_) => fail("expected no credential")
  }
}

///|
test "config source settings access and context-window override" {
  let source = ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object({
        "context_window": Json::number(32000.0),
        "endpoint": Json::string("https://example.invalid"),
      }),
    ),
  )
  assert_true(source.has_settings())
  assert_eq(
    source.setting("endpoint"),
    Some(Json::string("https://example.invalid")),
  )
  assert_eq(source.setting("missing"), None)
  assert_eq(source.context_window_setting(manifest_id="probe"), Some(32000))
  let malformed = ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object({ "context_window": Json::number(1.5) })),
  )
  let result = Ok(malformed.context_window_setting(manifest_id="probe")) catch {
    error => Err(error)
  }
  match result {
    Err(ManifestSchemaError(..)) => ()
    Err(other) => fail("unexpected error kind: \{other}")
    Ok(_) => fail("expected malformed context_window failure")
  }
  assert_false(ProviderConfigSource::ProviderConfigSource().has_settings())
}

///|
test "cached context windows restore offline discovery facts" {
  let slot = fake_slot(id="p/m", provider_id="p")
  let catalog = ProviderModelCatalog::ProviderModelCatalog(provider_id="p", slots=[
    slot,
  ])
  // Without cache records the declared window stays unknown.
  assert_eq(catalog.slots()[0].context_window, None)
  // Provider-stated discovery records restore as authoritative metadata.
  let records = Json::array([
    Json::object({
      "model_id": Json::string("model"),
      "context_window": Json::number(99000.0),
      "context_window_source": Json::string("provider"),
    }),
  ])
  let restored = catalog.with_cached_context_windows(Some(records))
  assert_eq(restored.slots()[0].context_window, Some(99000))
  assert_eq(restored.slots()[0].context_window_source, "provider_cache")
  // Derived windows must not become authoritative via the disk cache.
  let derived = Json::array([
    Json::object({
      "model_id": Json::string("model"),
      "context_window": Json::number(99000.0),
      "context_window_source": Json::string("fallback"),
    }),
  ])
  assert_eq(
    catalog.with_cached_context_windows(Some(derived)).slots()[0].context_window,
    None,
  )
  // Non-positive or malformed values are ignored.
  assert_eq(context_window_integer(Some(Json::number(0.0))), None)
  assert_eq(context_window_integer(Some(Json::string("x"))), None)
  assert_eq(context_window_integer(None), None)
}
