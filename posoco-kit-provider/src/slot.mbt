///|
/// Slot role in the selection vocabulary. `Chat` slots feed the conversation
/// selection (`/model`); `Decision` slots feed the semantic-judgement
/// selection (`/decision`). The two kinds are different models: a provider
/// advertises a slot as decision only when its extension also serves the
/// `DecisionPort` for it.
pub(all) enum ModelKind {
  Chat
  Decision
} derive(Eq, Debug)

///|
pub extend ModelKind with Eq::{not_equal, equal}

///|
pub extend ModelKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Stable wire id used by setup JSON and catalog projections.
pub fn ModelKind::to_id(self : ModelKind) -> String {
  match self {
    Chat => "chat"
    Decision => "decision"
  }
}

///|
/// Parse the wire id. `None` = not a kind name; callers decide whether that
/// is a composition failure or a default.
pub fn ModelKind::parse(text : String) -> ModelKind? {
  match text {
    "chat" => Some(Chat)
    "decision" => Some(Decision)
    _ => None
  }
}

///|
/// A selectable model slot.
///
/// The router owns selection state only. Hosts and provider extensions build
/// the ModelPort and inject it here, so the router does not know how a port is
/// configured, which protocol it speaks, or how credentials are obtained.
pub(all) struct ModelSlot {
  id : String
  label : String
  provider_id : String
  model_id : String
  port : &@posoco.ModelPort
  /// Slot role. Defaults to `Chat`; absent-from-JSON entries are read as
  /// chat so every existing catalog stays valid.
  kind : ModelKind
  /// DecisionPort owned by the slot's provider extension. `Some` only on
  /// `kind = Decision` slots; the router resolves the active decision
  /// capability from this field and never from another backend.
  decision_port : &@posoco.DecisionPort?
  oauth : &@oauth.OAuthProvider?
  api_key : &ApiKeyFactory?
  thinking_efforts : Array[String]
  /// Provider-declared context capacity, when the discovery endpoint reports
  /// one.  Hosts treat this as opaque metadata; it never drives selection.
  context_window : Int32?
  context_window_source : String
  /// Serving-provider key in models.dev; an empty key opts out of lookup.
  metadata_provider_id : String?
  /// Provider-declared capability identifiers for this model slot.
  capabilities : Array[String]
  /// Provider-declared default effort, if the model exposes thinking levels.
  default_effort : String?
  /// Provider-declared display group for picker tab presentation. Slots without
  /// a group are tabbed by their `provider_id`; grouped slots (e.g. custom
  /// OpenAI-compatible endpoints) share one tab while keeping their real
  /// `provider_id` for credentials and routing.
  display_group : String?
  rebuild_on_credential : ((@oauth.Credential) -> ModelSlot)?
  rebuild_on_api_key : ((@oauth.ApiKeyCredential) -> ModelSlot)?
  /// Provider-owned rebuild hook used when `/model` selects an effort.
  /// The router validates the advertised capability before invoking it.
  rebuild_on_effort : ((String) -> ModelSlot)?
}

///|
/// Construct a selectable model slot.
pub fn ModelSlot::ModelSlot(
  id~ : String,
  label~ : String,
  provider_id~ : String,
  model_id~ : String,
  port~ : &@posoco.ModelPort,
  kind~ : ModelKind = ModelKind::Chat,
  decision_port~ : &@posoco.DecisionPort? = None,
  oauth~ : &@oauth.OAuthProvider? = None,
  api_key~ : &ApiKeyFactory? = None,
  thinking_efforts~ : Array[String] = [],
  context_window~ : Int32? = None,
  context_window_source~ : String = "provider",
  metadata_provider_id~ : String? = None,
  capabilities~ : Array[String] = [],
  default_effort~ : String? = None,
  display_group~ : String? = None,
  rebuild_on_credential~ : ((@oauth.Credential) -> ModelSlot)? = None,
  rebuild_on_api_key~ : ((@oauth.ApiKeyCredential) -> ModelSlot)? = None,
  rebuild_on_effort~ : ((String) -> ModelSlot)? = None,
) -> ModelSlot {
  {
    id,
    label,
    provider_id,
    model_id,
    port,
    kind,
    decision_port,
    oauth,
    api_key,
    thinking_efforts,
    context_window,
    context_window_source,
    metadata_provider_id,
    capabilities,
    default_effort,
    display_group,
    rebuild_on_credential,
    rebuild_on_api_key,
    rebuild_on_effort,
  }
}

///|
/// `true` when the slot feeds the decision selection (`/decision`).
pub fn ModelSlot::is_decision(self : ModelSlot) -> Bool {
  self.kind is ModelKind::Decision
}

///|
/// `true` when the slot feeds the conversation selection (`/model`).
pub fn ModelSlot::is_chat(self : ModelSlot) -> Bool {
  self.kind is ModelKind::Chat
}
