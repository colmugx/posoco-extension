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
  oauth : &@oauth.OAuthProvider?
  api_key : &ApiKeyFactory?
  thinking_efforts : Array[String]
  /// Provider-declared context capacity, when the discovery endpoint reports
  /// one.  Hosts treat this as opaque metadata; it never drives selection.
  context_window : Int?
  /// Provider-declared capability identifiers for this model slot.
  capabilities : Array[String]
  /// Provider-declared default effort, if the model exposes thinking levels.
  default_effort : String?
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
  oauth? : &@oauth.OAuthProvider? = None,
  api_key? : &ApiKeyFactory? = None,
  thinking_efforts? : Array[String] = [],
  context_window? : Int? = None,
  capabilities? : Array[String] = [],
  default_effort? : String? = None,
  rebuild_on_credential? : ((@oauth.Credential) -> ModelSlot)? = None,
  rebuild_on_api_key? : ((@oauth.ApiKeyCredential) -> ModelSlot)? = None,
  rebuild_on_effort? : ((String) -> ModelSlot)? = None,
) -> ModelSlot {
  {
    id,
    label,
    provider_id,
    model_id,
    port,
    oauth,
    api_key,
    thinking_efforts,
    context_window,
    capabilities,
    default_effort,
    rebuild_on_credential,
    rebuild_on_api_key,
    rebuild_on_effort,
  }
}
