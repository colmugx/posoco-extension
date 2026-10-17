///|
/// Versioned, manager-qualified logical selection. IDs are opaque: no
/// provider/ or model-name parsing belongs in callers of this contract.
/// The revision is scoped to the owning runtime generation.
pub(all) struct SelectionRef {
  owner : String
  model_id : String
  effort : String?
  pending : Bool
  revision : Int64
} derive(Eq, Debug)

///|
pub extend SelectionRef with Eq::{not_equal, equal}

///|
pub extend SelectionRef with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Snapshot the active manager without depending on its concrete adapter.
/// Call only after a successful selection commit (never on a failed switch).
pub fn selection_ref(
  control : &ModelManagerControl,
  revision~ : Int64 = 0L,
) -> SelectionRef {
  let selected = control.active_selection()
  {
    owner: control.manager_id(),
    model_id: selected.model_id,
    effort: selected.effort,
    pending: selected.pending,
    revision,
  }
}

///|
/// Fail closed on malformed or unqualified identities.
pub fn SelectionRef::valid(self : SelectionRef) -> Bool {
  !self.owner.is_empty() && !self.model_id.is_empty() && self.revision >= 0L
}

///|
/// Reusable observation vocabulary for all optional model capabilities.
/// Absence, lack of implementation, stale data and transient unavailability
/// are distinct; consumers must not render any of them as zero.
pub(all) enum ModelObservation[T] {
  Known(T, observed_at_ms~ : Int64, provenance~ : String)
  Stale(T, observed_at_ms~ : Int64, provenance~ : String)
  Unknown(String)
  Unavailable(String)
  Unsupported
}
