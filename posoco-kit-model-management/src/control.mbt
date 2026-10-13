///|
/// control.mbt — posoco-kit-model-management: the shared, provider-neutral
/// control contract every Model Manager implements.

///|
/// Provider-neutral metadata for one selectable model, as a manager's
/// catalog reports it. `model_id` is the opaque selection key handed back to
/// `select_model`; no provider, manager, or `provider/model` slash shape is
/// assumed. A missing fact stays missing: an unknown context window is
/// `None`, never a fabricated default.
pub(all) struct ManagerModelInfo {
  /// Opaque manager-local selection key.
  model_id : String
  /// Human-facing display name.
  label : String
  /// Identity of the serving provider inside this manager (credential and
  /// routing scope); a standalone manager may use a single fixed id.
  provider_id : String
  /// Provider-declared context capacity in tokens; `None` = unknown.
  context_window : Int32?
  /// Provider-declared capability identifiers.
  capabilities : Array[String]
  /// Advertised reasoning efforts, ordered least to most.
  efforts : Array[String]
  /// Provider-declared default effort, when the model exposes levels.
  default_effort : String?
  /// Optional display grouping for pickers; `None` = group by provider.
  display_group : String?
} derive(Eq, Debug)

///|
pub extend ManagerModelInfo with Eq::{not_equal, equal}

///|
pub extend ManagerModelInfo with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The manager's current logical selection.
pub(all) struct ManagerSelection {
  /// Selected model id, exactly as persisted. It may be absent from the
  /// current catalog — see `pending`.
  model_id : String
  /// Effort explicitly applied on top of the model's own default;
  /// `None` = no explicit effort selection.
  effort : String?
  /// `true` when `model_id` is absent from `list_models`: a persisted
  /// selection waiting for its model to appear (login, refresh, discovery).
  /// Pending selections are reported as-is, never silently rewritten to a
  /// fabricated default; requests against them fail visibly until they heal.
  pending : Bool
} derive(Eq, Debug)

///|
pub extend ManagerSelection with Eq::{not_equal, equal}

///|
pub extend ManagerSelection with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Typed failures of the manager control contract. A failed call never
/// mutates state: the previous selection, effort, and catalog stay exactly
/// as they were.
pub(all) suberror ModelManagerError {
  /// The target model id is absent from the manager's catalog. Also raised
  /// when an effort is applied to a pending active selection.
  UnknownModel(String)
  /// The effort is not advertised by the target model.
  UnsupportedEffort(String)
  /// The model advertises efforts but the manager cannot apply one.
  EffortNotApplicable(String)
} derive(Debug)

///|
pub extend ModelManagerError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ModelManagerError with Show::{to_string, output}

///|
pub impl Show for ModelManagerError with fn to_string(self) -> String {
  match self {
    UnknownModel(detail) => "ModelManagerError::UnknownModel(\{detail})"
    UnsupportedEffort(detail) =>
      "ModelManagerError::UnsupportedEffort(\{detail})"
    EffortNotApplicable(detail) =>
      "ModelManagerError::EffortNotApplicable(\{detail})"
  }
}

///|
/// Control surface shared by every Model Manager.
///
/// A Model Manager owns a model catalog, the active selection, and the
/// reasoning effort applied on top of it. This trait is the whole control
/// vocabulary peer managers agree on: `posoco-ext-llm` implements it for the
/// local slot router, and independent managers (the future
/// `posoco-ext-magpie`) implement it without depending on the local manager,
/// on any provider extension, or on a transport. Hosts drive any manager
/// through a plain trait reference.
///
/// The contract is deliberately small and control-plane only: no `ModelPort`,
/// no `ModelSlot`, no credential flow. Model ids are opaque. Switching the
/// active model resets any applied effort; selecting an effort is validated
/// against the active model's own advertised levels.
pub(open) trait ModelManagerControl {
  /// Stable manager identity, unique per manager implementation and stable
  /// across sessions (e.g. `"posoco_ext_llm"`, `"magpie"`).
  fn manager_id(Self) -> String

  /// Ordered catalog snapshot in the manager's own presentation order.
  /// Entry arrays are copies: later catalog changes never mutate a returned
  /// snapshot.
  fn list_models(Self) -> Array[ManagerModelInfo]

  /// Current logical selection and applied effort. A persisted selection
  /// whose model is absent from the catalog reports `pending = true`
  /// instead of being rewritten.
  fn active_selection(Self) -> ManagerSelection

  /// Validate and switch the active model; any applied effort is reset.
  /// Unknown ids raise `UnknownModel` without mutating state.
  fn select_model(Self, model_id : String) -> Unit raise ModelManagerError

  /// Validate and apply a reasoning effort to the active model. Raises
  /// `UnknownModel` (absent or pending selection), `UnsupportedEffort`
  /// (effort not advertised), or `EffortNotApplicable` (no way to apply
  /// one) without corrupting state.
  fn select_effort(Self, effort : String) -> Unit raise ModelManagerError
}
