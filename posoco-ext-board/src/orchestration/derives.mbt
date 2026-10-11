///|
pub extend ExecutionInputStatus with Eq::{equal, not_equal}

///|
pub extend ExecutionInputStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ExecutionInputAvailability with Eq::{equal, not_equal}

///|
pub extend ExecutionInputAvailability with @moonbitlang/core/debug.Debug::{
  to_repr,
}

///|
pub extend ExecutionBlockReason with Eq::{equal, not_equal}

///|
pub extend ExecutionBlockReason with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ExecutionCandidate with Eq::{equal, not_equal}

///|
pub extend ExecutionCandidate with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend BlockedExecution with Eq::{equal, not_equal}

///|
pub extend BlockedExecution with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ExecutionPlan with Eq::{equal, not_equal}

///|
pub extend ExecutionPlan with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend OrchestrationError with Eq::{equal, not_equal}

///|
pub extend OrchestrationError with @moonbitlang/core/debug.Debug::{to_repr}
