///|
/// `posoco-kit-events` — the closed cross-extension event protocol on top of
/// posoco's open `@events.Event`.
///
/// Before this package, extensions published Json payloads on string topics
/// through the devkit event bus (`"status"`, `"tool_exemptions"`,
/// `"model_selection"`, `"decision_selection"`, `"provider"`,
/// `"profiles.activated"`). Each of those payloads is now a closed ADT plus an
/// `@events.Event` constructor defined **here**: publishers publish typed
/// values, subscribers pattern match exhaustively, and no Json codec, downcast
/// or runtime registry sits in between.
///
/// Rules kept from the migration plan (`extension/docs/events-migration.md`):
/// payload fields mirror the legacy Json keys one for one — nothing added,
/// renamed or dropped; payloads are immutable data (posoco delivers a
/// community event as published, it is not deep copied); and every constructor
/// is declared in this defining package, so consumers must qualify it
/// (`@kit_events.StatusChanged`, never `@posoco.StatusChanged`).
///
/// Publishers keep their identity in the capability they hold, not in a
/// payload field: `system.publisher(owner="posoco_ext_llm")` binds every
/// publication to `Extension("posoco_ext_llm")`. Subscribers that used to
/// filter on `BusEvent.source` filter on `publisher_id(envelope)` instead.

///|
/// One status-bar operation, mirroring the legacy `"status"` topic payload
/// byte for byte.
///
/// Legacy Json (published by `@devkit.publish_status_*`):
/// - register: `{"op":"register","segment":s,"priority":p}` plus `label`,
///   `value` and `color` only when present;
/// - update: `{"op":"update","segment":s,"value":v}`;
/// - unregister: `{"op":"unregister","segment":s}`.
///
/// `color` is a semantic role from `@devkit.status_color_roles()`, never a raw
/// color value; `priority` orders segments on the bar (ascending, left to
/// right). The segment-ownership rule (the first register-or-update source
/// owns a segment) is the bridge's, not the protocol's.
#derive(Eq, Debug)
pub(all) enum StatusOp {
  Register(
    segment~ : String,
    label~ : String?,
    priority~ : Int32,
    value~ : String?,
    color~ : String?
  )
  Update(segment~ : String, value~ : String)
  Unregister(segment~ : String)
}

///|
pub extend StatusOp with Eq::{not_equal, equal}

///|
pub extend StatusOp with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Legacy topic `"tool_exemptions"`: the exact tool names (no patterns) that
/// carry their own governance, published by the plan extension (and bunraku's
/// `run_code` transport) so a subscribed approval gate lets them bypass its
/// checks. Legacy Json: `{"tools": [string, ...]}`.
#derive(Eq, Debug)
pub(all) struct ToolExemptionsPayload {
  tools : Array[String]
}

///|
pub extend ToolExemptionsPayload with Eq::{not_equal, equal}

///|
pub extend ToolExemptionsPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Legacy topic `"model_selection"`: one machine-readable selection fact per
/// change, published by the ext-llm router. `slot_id` is the active router
/// slot id; a `None` `effort` means the slot default (legacy `null`). The
/// vocabulary matches the persisted `ActiveModelSelection`, so the fs-session
/// store records it into session metadata and a resume restores it.
/// Legacy Json: `{"slot_id": string, "effort": string | null}`.
#derive(Eq, Debug)
pub(all) struct ModelSelectionPayload {
  slot_id : String
  effort : String?
}

///|
pub extend ModelSelectionPayload with Eq::{not_equal, equal}

///|
pub extend ModelSelectionPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Legacy topic `"decision_selection"`: the router's decision-capability
/// state, published on every selection change and at composition. `slot_id`
/// is the selected `kind = Decision` slot (`""` = nothing selected);
/// `available` states whether the capability can serve calls right now, and
/// `reason` explains an off state (`None` = legacy `null`, on). Legacy Json:
/// `{"slot_id": string, "available": bool, "reason": string | null}`.
#derive(Eq, Debug)
pub(all) struct DecisionSelectionPayload {
  slot_id : String
  available : Bool
  reason : String?
}

///|
pub extend DecisionSelectionPayload with Eq::{not_equal, equal}

///|
pub extend DecisionSelectionPayload with @moonbitlang/core/debug.Debug::{
  to_repr,
}

///|
/// Legacy topic `"provider"`: the provider the router announced as active, at
/// composition and on every switch, idempotently. Provider-scoped publishers
/// (the Codex quota windows) show or hide their segments on it. Legacy Json:
/// `{"provider_id": string}`.
#derive(Eq, Debug)
pub(all) struct ProviderStatusPayload {
  provider_id : String
}

///|
pub extend ProviderStatusPayload with Eq::{not_equal, equal}

///|
pub extend ProviderStatusPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Legacy topic `"profiles.activated"`: one profile was activated. `id` is
/// the profile id and `members` its member extension ids. Legacy Json:
/// `{"id": string, "members": [string, ...]}`.
#derive(Eq, Debug)
pub(all) struct ProfilesActivatedPayload {
  id : String
  members : Array[String]
}

///|
pub extend ProfilesActivatedPayload with Eq::{not_equal, equal}

///|
pub extend ProfilesActivatedPayload with @moonbitlang/core/debug.Debug::{
  to_repr,
}

///|
/// The cross-extension protocol: one constructor per legacy topic, each
/// carrying its closed payload. Matching on `@events.Event` needs a wildcard
/// branch (the type is open); the payload ADTs stay exhaustive.
pub(all) extenum @events.Event += {
  StatusChanged(StatusOp)
  ToolExemptions(ToolExemptionsPayload)
  ModelSelection(ModelSelectionPayload)
  DecisionSelection(DecisionSelectionPayload)
  ProviderStatus(ProviderStatusPayload)
  ProfilesActivated(ProfilesActivatedPayload)
}

///|
/// The publishing extension id carried by `envelope`, or `None` for core
/// (`Posoco`) notifications. This is the typed replacement for the legacy
/// `BusEvent.source` filter: a capability bound to
/// `system.publisher(owner="posoco_ext_llm")` stamps every event it publishes
/// with `Extension("posoco_ext_llm")`.
pub fn publisher_id(envelope : @events.EventEnvelope) -> String? {
  match envelope.namespace_of() {
    @events.Extension(id) => Some(id)
    @events.Posoco => None
  }
}

///|
/// The `StatusChanged` payload of `envelope`, or `None` for any other event.
pub fn status_changed_of(envelope : @events.EventEnvelope) -> StatusOp? {
  match envelope.event {
    StatusChanged(op) => Some(op)
    _ => None
  }
}

///|
/// The `ToolExemptions` payload of `envelope`, or `None` for any other event.
pub fn tool_exemptions_of(
  envelope : @events.EventEnvelope,
) -> ToolExemptionsPayload? {
  match envelope.event {
    ToolExemptions(payload) => Some(payload)
    _ => None
  }
}

///|
/// The `ModelSelection` payload of `envelope`, or `None` for any other event.
pub fn model_selection_of(
  envelope : @events.EventEnvelope,
) -> ModelSelectionPayload? {
  match envelope.event {
    ModelSelection(payload) => Some(payload)
    _ => None
  }
}

///|
/// The `DecisionSelection` payload of `envelope`, or `None` for any other
/// event.
pub fn decision_selection_of(
  envelope : @events.EventEnvelope,
) -> DecisionSelectionPayload? {
  match envelope.event {
    DecisionSelection(payload) => Some(payload)
    _ => None
  }
}

///|
/// The `ProviderStatus` payload of `envelope`, or `None` for any other event.
pub fn provider_status_of(
  envelope : @events.EventEnvelope,
) -> ProviderStatusPayload? {
  match envelope.event {
    ProviderStatus(payload) => Some(payload)
    _ => None
  }
}

///|
/// The `ProfilesActivated` payload of `envelope`, or `None` for any other
/// event.
pub fn profiles_activated_of(
  envelope : @events.EventEnvelope,
) -> ProfilesActivatedPayload? {
  match envelope.event {
    ProfilesActivated(payload) => Some(payload)
    _ => None
  }
}
