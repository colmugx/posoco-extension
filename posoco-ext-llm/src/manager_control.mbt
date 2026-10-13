///|
/// Manager-control contract for the slot router.
///
/// The adapter projects the router's existing public API onto
/// `@modelmgmt`'s manager-neutral vocabulary and owns no routing logic of
/// its own: `switch_slot` stays the single writer of selection state and
/// `select_effort` stays the single effort validator, so the shared contract
/// inherits their invariants (effort reset, model/ctx status publication,
/// provider event, quota invalidation) instead of copying them. The
/// `/model`, `/effort`, `/login`, and `/status` commands are untouched —
/// they remain the interactive surface with their publishing and quota
/// behavior.

///|
pub impl @modelmgmt.ModelManagerControl for RouterModelPort with fn manager_id(
  _self : RouterModelPort,
) -> String {
  "posoco_ext_llm"
}

///|
/// Project one slot onto the manager-neutral metadata. `model_id` carries
/// the slot id verbatim — the selection key is opaque and is never split on
/// `/`. The provider-declared context window passes through as-is: `None`
/// stays unknown instead of inheriting the status bar's display fallback.
fn project_slot_metadata(slot : ModelSlot) -> @modelmgmt.ManagerModelInfo {
  {
    model_id: slot.id,
    label: slot.label,
    provider_id: slot.provider_id,
    context_window: slot.context_window,
    capabilities: slot.capabilities.copy(),
    efforts: slot.thinking_efforts.copy(),
    default_effort: slot.default_effort,
    display_group: slot.display_group,
  }
}

///|
pub impl @modelmgmt.ModelManagerControl for RouterModelPort with fn list_models(
  self : RouterModelPort,
) -> Array[@modelmgmt.ManagerModelInfo] {
  self.list_slots().map(project_slot_metadata)
}

///|
pub impl @modelmgmt.ModelManagerControl for RouterModelPort with fn active_selection(
  self : RouterModelPort,
) -> @modelmgmt.ManagerSelection {
  {
    model_id: self.active_id,
    effort: self.active_effort,
    pending: !self.slots.contains(self.active_id),
  }
}

///|
pub impl @modelmgmt.ModelManagerControl for RouterModelPort with fn select_model(
  self : RouterModelPort,
  model_id : String,
) -> Unit raise @modelmgmt.ModelManagerError {
  // `switch_slot` owns validation, effort reset, model-status publication,
  // the provider event, and quota invalidation; its only failure mode is an
  // unknown slot id.
  self.switch_slot(model_id) catch {
    _ =>
      raise @modelmgmt.ModelManagerError::UnknownModel(
        "unknown model slot: " + model_id,
      )
  }
}

///|
pub impl @modelmgmt.ModelManagerControl for RouterModelPort with fn select_effort(
  self : RouterModelPort,
  effort : String,
) -> Unit raise @modelmgmt.ModelManagerError {
  // A pending active selection has no catalog entry to validate against;
  // report it as unknown rather than letting the slot lookup phrase it.
  if !self.slots.contains(self.active_id) {
    raise @modelmgmt.ModelManagerError::UnknownModel(
      "active model slot is not in the catalog: " + self.active_id,
    )
  }
  // The existing public method owns effort validation and the
  // provider-owned rebuild hook. With the slot known to exist, its
  // `InvalidArgs` arm can only be an unsupported effort.
  RouterModelPort::select_effort(self, self.active_id, effort) catch {
    @posoco.CommandError::InvalidArgs(reason~) =>
      raise @modelmgmt.ModelManagerError::UnsupportedEffort(reason)
    @posoco.CommandError::ExecutionFailed(detail) =>
      raise @modelmgmt.ModelManagerError::EffortNotApplicable(detail)
    // Unreachable today: `select_effort` never raises `NotFound`. Mapped
    // defensively so a future core change surfaces as an unknown slot
    // instead of an untyped escape.
    @posoco.CommandError::NotFound(id) =>
      raise @modelmgmt.ModelManagerError::UnknownModel(
        "unknown model slot: " + id,
      )
  }
}
