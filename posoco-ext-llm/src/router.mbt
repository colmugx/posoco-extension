///|
/// router.mbt — ModelPort aggregator with host-injected model slots.
///
/// The router is deliberately unaware of provider adapters, endpoint
/// configuration, model discovery, and credential transport. A host composes
/// ModelSlot values and injects already-constructed ModelPorts.

///|
pub(all) struct RouterModelPort {
  slots : Map[String, ModelSlot]
  slot_order : Array[String]
  mut active_id : String
  mut active_effort : String?
  /// Canonical one-record store. When present, login writes a tagged
  /// ProviderCredential and replaces the previous method atomically.
  provider_credential_store : &@oauth.ProviderCredentialStore?
  cred_store : &@oauth.CredentialStore?
  auth_interaction : &@oauth.AuthInteraction?
  api_key_store : &@oauth.ApiKeyStore?
  auth_prompt : &@oauth.AuthPromptInteraction?
  credentials : Map[String, @oauth.Credential]
  api_key_credentials : Map[String, @oauth.ApiKeyCredential]
}

///|
/// Construct a router from a non-empty, uniquely keyed slot list.
///
/// An empty default id selects the first slot in insertion order. Composition
/// failures are raised before the router is returned, so callers never see a
/// partially populated routing table.
pub fn RouterModelPort::new(
  slots~ : Array[ModelSlot],
  default_slot_id? : String = "",
  provider_credential_store? : &@oauth.ProviderCredentialStore? = None,
  cred_store? : &@oauth.CredentialStore? = None,
  auth_interaction? : &@oauth.AuthInteraction? = None,
  api_key_store? : &@oauth.ApiKeyStore? = None,
  auth_prompt? : &@oauth.AuthPromptInteraction? = None,
) -> RouterModelPort raise @posoco.CompositionError {
  if slots.is_empty() {
    raise @posoco.CompositionError::EmptyPort("posoco_ext_llm.slots")
  }
  let slot_map : Map[String, ModelSlot] = Map::from_array([])
  let slot_order : Array[String] = []
  for slot in slots {
    if slot.id.length() == 0 {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_llm",
        detail="model slot id must not be empty",
      )
    }
    if slot_map.contains(slot.id) {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_llm",
        detail="duplicate model slot id: " + slot.id,
      )
    }
    slot_map[slot.id] = slot
    slot_order.push(slot.id)
  }
  let active_id = if default_slot_id.length() == 0 {
    slot_order[0]
  } else {
    if !slot_map.contains(default_slot_id) {
      raise @posoco.CompositionError::ManifestSchemaError(
        manifest_id="posoco_ext_llm",
        detail="unknown default model slot: " + default_slot_id,
      )
    }
    default_slot_id
  }
  {
    slots: slot_map,
    slot_order,
    active_id,
    active_effort: None,
    provider_credential_store,
    cred_store,
    auth_interaction,
    api_key_store,
    auth_prompt,
    credentials: Map::from_array([]),
    api_key_credentials: Map::from_array([]),
  }
}

///|
/// Construct a router from provider-owned catalogs. Each provider extension
/// builds its own slots and capability metadata; this function only flattens
/// catalogs and lets `new` perform the final collision check.
pub fn RouterModelPort::from_catalogs(
  catalogs : Array[ProviderModelCatalog],
  default_slot_id? : String = "",
  provider_credential_store? : &@oauth.ProviderCredentialStore? = None,
  cred_store? : &@oauth.CredentialStore? = None,
  auth_interaction? : &@oauth.AuthInteraction? = None,
  api_key_store? : &@oauth.ApiKeyStore? = None,
  auth_prompt? : &@oauth.AuthPromptInteraction? = None,
) -> RouterModelPort raise @posoco.CompositionError {
  let slots : Array[ModelSlot] = []
  for catalog in catalogs {
    for slot in catalog.slots() {
      slots.push(slot)
    }
  }
  RouterModelPort::new(
    slots~,
    default_slot_id~,
    provider_credential_store~,
    cred_store~,
    auth_interaction~,
    api_key_store~,
    auth_prompt~,
  )
}

///|
/// Return the active slot. A missing active slot is an internal invariant
/// violation and must fail loudly instead of silently falling back.
fn RouterModelPort::active_slot(self : RouterModelPort) -> ModelSlot {
  match self.slots.get(self.active_id) {
    Some(slot) => slot
    None =>
      abort(
        "posoco_ext_llm router invariant violated: active slot is missing: " +
        self.active_id,
      )
  }
}

///|
/// Return slots in the same order in which they were composed.
pub fn RouterModelPort::list_slots(self : RouterModelPort) -> Array[ModelSlot] {
  let result : Array[ModelSlot] = []
  for id in self.slot_order {
    match self.slots.get(id) {
      Some(slot) => result.push(slot)
      None =>
        abort(
          "posoco_ext_llm router invariant violated: ordered slot is missing: " +
          id,
        )
    }
  }
  result
}

///|
/// Return all slot ids in composition order.
pub fn RouterModelPort::list_slot_ids(self : RouterModelPort) -> Array[String] {
  self.slot_order.copy()
}

///|
/// Return the active slot id.
pub fn RouterModelPort::active_slot_id(self : RouterModelPort) -> String {
  self.active_id
}

///|
/// Return the provider id of the active slot.
pub fn RouterModelPort::current_provider_id(self : RouterModelPort) -> String {
  self.active_slot().provider_id
}

///|
/// Return the provider-local model id of the active slot.
pub fn RouterModelPort::current_model_id(self : RouterModelPort) -> String {
  self.active_slot().model_id
}

///|
/// The selected effort for the active slot, if `/model` has selected one.
pub fn RouterModelPort::active_effort(self : RouterModelPort) -> String? {
  self.active_effort
}

///|
/// Select a slot without rebuilding its ModelPort.
pub fn RouterModelPort::switch_slot(
  self : RouterModelPort,
  slot_id : String,
) -> Unit raise @posoco.CompositionError {
  if !self.slots.contains(slot_id) {
    raise @posoco.CompositionError::ManifestSchemaError(
      manifest_id="posoco_ext_llm",
      detail="unknown model slot: " + slot_id,
    )
  }
  self.active_id = slot_id
  self.active_effort = None
}

///|
pub impl @posoco.ModelPort for RouterModelPort with fn chat(
  self : RouterModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.active_slot().port.chat(messages, tools, options, stream)
}

///|
pub impl @posoco.ModelPort for RouterModelPort with fn compact(
  self : RouterModelPort,
  messages : Array[@posoco.Message],
  options : @posoco.ChatOptions,
  trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  self.active_slot().port.compact(messages, options, trigger)
}

///|
pub impl @posoco.ModelPort for RouterModelPort with fn provider_config(
  self : RouterModelPort,
) -> @posoco.ProviderConfig {
  self.active_slot().port.provider_config()
}
