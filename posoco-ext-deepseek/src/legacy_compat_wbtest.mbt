///|
/// Legacy-surface compatibility proof: the historical `@llm` provider names
/// re-export the canonical `colmugx/posoco-kit-provider` types, so an
/// external consumer can implement `@llm.ProviderFactory` and construct
/// `@llm.ModelSlot` / `@llm.ProviderModelCatalog` values that are the same
/// types the kit (and the Router) consume. No parallel representation.

///|
/// Inert port: slot composition requires a ModelPort; never dispatched here.
struct LegacyPort {}

///|
impl @posoco.ModelPort for LegacyPort with fn chat(
  _self : LegacyPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  raise @posoco.ModelError::Transport("legacy port was not expected to chat")
}

///|
impl @posoco.ModelPort for LegacyPort with fn compact(
  _self : LegacyPort,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse(
    "legacy port does not implement compact",
  )
}

///|
impl @posoco.ModelPort for LegacyPort with fn provider_config(
  _self : LegacyPort,
) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
/// A factory implemented entirely through the historical `@llm` names.
struct LegacyFactory {
  id : String
}

///|
impl @llm.ProviderFactory for LegacyFactory with fn provider_id(
  self : LegacyFactory,
) -> String {
  self.id
}

///|
impl @llm.ProviderFactory for LegacyFactory with fn credential_id(
  self : LegacyFactory,
) -> String {
  self.id
}

///|
impl @llm.ProviderFactory for LegacyFactory with fn build(
  self : LegacyFactory,
  source : @llm.ProviderConfigSource,
) -> @llm.ProviderBuildResult raise @posoco.CompositionError {
  if source.effective_credential(self.id) is None {
    return @llm.ProviderBuildResult::Unconfigured
  }
  let slot : @llm.ModelSlot = @llm.ModelSlot::ModelSlot(
    id="\{self.id}/m",
    label="m",
    provider_id=self.id,
    model_id="m",
    port=LegacyPort::{ },
  )
  @llm.ProviderBuildResult::Ready(
    @llm.ProviderModelCatalog::ProviderModelCatalog(provider_id=self.id, slots=[
      slot,
    ]),
  )
}

///|
/// Canonical-typed parameter: a value obtained through `@llm.` names must be
/// the very same type, not a convertible copy.
fn canonical_provider_id(catalog : @provider.ProviderModelCatalog) -> String {
  catalog.provider_id()
}

///|
fn canonical_factory_builds(
  factory : &@provider.ProviderFactory,
  source : @provider.ProviderConfigSource,
) -> Bool raise @posoco.CompositionError {
  factory.build(source) is @provider.ProviderBuildResult::Ready(_)
}

///|
test "legacy @llm names denote the canonical provider types" {
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    provider_credential=Some(
      @oauth.ProviderCredential::ApiKey(
        @oauth.ApiKeyCredential::ApiKeyCredential(secret="k"),
      ),
    ),
  )
  // The @llm-implemented factory satisfies the canonical trait reference.
  let factory : &@provider.ProviderFactory = LegacyFactory::{ id: "legacy", }
    as &@provider.ProviderFactory
  assert_true(canonical_factory_builds(factory, source))
  // The built catalog flows into canonical-typed bindings unchanged.
  guard factory.build(source) is @provider.ProviderBuildResult::Ready(catalog) else {
    fail("expected a ready catalog")
  }
  assert_eq(canonical_provider_id(catalog), "legacy")
  // Struct syntax through the legacy path equals the canonical path.
  let via_legacy : @llm.ModelSlot = catalog.slots()[0]
  let via_canonical : @provider.ModelSlot = catalog.slots()[0]
  assert_eq(via_legacy.id, via_canonical.id)
  assert_eq(via_legacy.provider_id, via_canonical.provider_id)
  // The Router consumes the legacy-path catalog directly.
  let router = @llm.RouterModelPort::from_catalogs([catalog])
  assert_eq(router.active_slot_id(), "legacy/m")
}
