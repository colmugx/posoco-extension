///|
/// Provider-neutral facts consumed by status, quota, usage and recovery UI.
/// A Model Manager owns its own routing; these are read-only observations,
/// not another decision-making router.

///|
/// An explicit selection and its context capacity. Missing capacity is
/// unknown, not unlimited. The selected logical model can differ from the
/// model which ultimately served a call.
pub(all) struct ModelStatusFacts {
  selection : SelectionRef
  context_used_tokens : Int64?
  context_capacity_tokens : Int64?
  last_served_model_id : String?
  observed_at_ms : Int64
} derive(Eq, Debug)

///|
pub extend ModelStatusFacts with Eq::{not_equal, equal}

///|
pub extend ModelStatusFacts with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A compact status should never pretend stale/absent model facts are zero.
pub fn ModelStatusFacts::context_percent(
  self : ModelStatusFacts,
) -> Double? {
  match (self.context_used_tokens, self.context_capacity_tokens) {
    (Some(used), Some(capacity)) if used >= 0L && capacity > 0L =>
      Some(used.to_double() * 100.0 / capacity.to_double())
    _ => None
  }
}

///|
/// Observers provide a single neutral facts interface; each manager adapter
/// can return Known, Stale, Unknown, Unavailable, or Unsupported.
pub(open) trait ModelFactsSource {
  fn model_facts(Self) -> ModelObservation[ModelStatusFacts]
}

///|
/// An upstream quota window. A named 5h or weekly allowance belongs to its
/// own source, and is never averaged/summed with another source's percent.
pub(all) struct ModelQuotaWindow {
  name : String
  remaining_percent : Double?
  resets_at_ms : Int64?
  unlimited : Bool?
} derive(Eq, Debug)

///|
pub extend ModelQuotaWindow with Eq::{not_equal, equal}

///|
pub extend ModelQuotaWindow with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Source identities must be opaque and non-secret. This struct intentionally
/// has neither an email nor a raw API key field.
pub(all) struct ModelQuotaSourceSnapshot {
  source_ref : String
  display_label : String
  windows : Array[ModelQuotaWindow]
  eligible : Bool?
  observed_at_ms : Int64?
} derive(Eq, Debug)

///|
pub extend ModelQuotaSourceSnapshot with Eq::{not_equal, equal}

///|
pub extend ModelQuotaSourceSnapshot with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Model-local quota observations; no pooled remaining-percent property.
/// A model can be served by several sources with incompatible quota windows.
pub(all) struct ModelQuotaSnapshot {
  selection : SelectionRef
  sources : Array[ModelQuotaSourceSnapshot]
  observed_at_ms : Int64
} derive(Eq, Debug)

///|
pub extend ModelQuotaSnapshot with Eq::{not_equal, equal}

///|
pub extend ModelQuotaSnapshot with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(open) trait ModelQuotaSource {
  fn model_quota(Self, SelectionRef) -> ModelObservation[ModelQuotaSnapshot]
}

///|
/// A caller's budget is distinct from every underlying subscription limit.
pub(all) struct ModelBudgetSnapshot {
  budget_label : String
  remaining : Double?
  currency : String?
  resets_at_ms : Int64?
  observed_at_ms : Int64
} derive(Eq, Debug)

///|
pub extend ModelBudgetSnapshot with Eq::{not_equal, equal}

///|
pub extend ModelBudgetSnapshot with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(open) trait ModelBudgetSource {
  fn model_budget(Self) -> ModelObservation[ModelBudgetSnapshot]
}

///|
/// The call's actual execution provenance is observational. It must not be
/// used as a prediction for a future routing decision.
pub(all) struct ModelExecutionFacts {
  requested_model_id : String
  served_model_id : String?
  served_source_ref : String?
  observed_at_ms : Int64
} derive(Eq, Debug)

///|
pub extend ModelExecutionFacts with Eq::{not_equal, equal}

///|
pub extend ModelExecutionFacts with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(open) trait ModelExecutionFactsSource {
  fn last_execution_facts(Self) -> ModelObservation[ModelExecutionFacts]
}

///|
/// Recovery advice describes a router's final verdict after any internal
/// failover. It does not trigger retries itself: the generic supervisor
/// decides when a failed turn is safe to resume.
pub(all) enum ModelRecoveryAdvice {
  WaitUntil(Int64)
  ProbeWithBackoff
  Stop(String)
  Unknown
} derive(Eq, Debug)

///|
pub extend ModelRecoveryAdvice with Eq::{not_equal, equal}

///|
pub extend ModelRecoveryAdvice with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A deadline may be missing. A missing deadline is not "retry immediately".
pub fn ModelRecoveryAdvice::deadline(
  self : ModelRecoveryAdvice,
) -> Int64? {
  match self {
    WaitUntil(at) if at > 0L => Some(at)
    _ => None
  }
}

///|
/// A source may expose extra model-management capabilities, but no consumer
/// may assume they are always implemented.
pub(open) trait ModelRecoverySource {
  fn recovery_advice(Self) -> ModelObservation[ModelRecoveryAdvice]
}

///|
/// A small adapter from any active ModelManagerControl into the common
/// status facts vocabulary. This is not another Router: it observes only
/// the opaque active selection and its catalog-declared context capacity.
/// Usage/context consumption is intentionally left unknown until provided
/// by Core's current scoped ContextState.
pub struct ManagerStatusAdapter {
  control : &ModelManagerControl
  observed_at_ms : Int64
}

///|
pub fn ManagerStatusAdapter::ManagerStatusAdapter(
  control : &ModelManagerControl,
  observed_at_ms~ : Int64,
) -> ManagerStatusAdapter {
  { control, observed_at_ms, }
}

///|
pub impl ModelFactsSource for ManagerStatusAdapter with fn model_facts(
  self : ManagerStatusAdapter,
) -> ModelObservation[ModelStatusFacts] {
  let selection = selection_ref(self.control)
  if !selection.valid() {
    return ModelObservation::Unknown("no active selection")
  }
  let mut capacity : Int64? = None
  for model in self.control.list_models() {
    if model.model_id == selection.model_id {
      capacity = match model.context_window {
        Some(n) if n > 0 => Some(n.to_int64())
        _ => None
      }
      break
    }
  }
  ModelObservation::Known(
    {
      selection,
      context_used_tokens: None,
      context_capacity_tokens: capacity,
      last_served_model_id: None,
      observed_at_ms: self.observed_at_ms,
    },
    observed_at_ms=self.observed_at_ms,
    provenance="model-management",
  )
}

///|
pub extend ManagerStatusAdapter with ModelFactsSource::{model_facts}
